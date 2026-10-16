# TypeScript virtual filename directive casing

This is a partial input-fidelity repair for [#841](https://github.com/home-lang/home/issues/841). The TypeScript conformance fixture `ts-expect-error-js.ts` declares `// @fileName: a.js`. Home recognized only `@filename:` and `@Filename:`, so it compiled the case under the physical fixture name and reported `ts-expect-error-js.ts(3,1)` instead of the upstream baseline's `a.js(3,1)`.

Virtual filename detection now uses the same case-insensitive directive-key parser as the rest of the harness. The virtual-file index, section stripping, first-code filename selection, and program routing therefore agree on mixed-case `@fileName` and `@FILENAME` markers. It requires a nonempty path and a directive comment rather than accepting an embedded marker in arbitrary source text. The regression test covers all four consumers and those two invalid forms.

All substantial runs were serial through `run_bounded` with `HOME_RUN_MAX_MB=3840`:

| Control | Zig 0.17 | Zig 0.18 |
| --- | --- | --- |
| Mixed-case marker regression | 2/2 pass | compiled by the exact run; not separately run |
| Existing `buildVirtualFileIndex` group | 5/5 pass | not run |
| Exact upstream `ts-expect-error-js` case | 1/1 pass | 1/1 pass |
| Peak process-tree footprint for exact run | 352 MB | 2,135 MB including compilation |

Before the change, the exact case failed solely on the diagnostic filename. With the change, its program-compiler path took about two minutes on each Zig version. A 120-second bound expired without a result, then a 240-second guarded run completed on each version. The prior five-case window also expired at 240 seconds and is **not** credited as passing. This evidence establishes one exact fixture, not the full corpus or Bun parity. The remaining conformance and performance work stays open under [#841](https://github.com/home-lang/home/issues/841) and [#66](https://github.com/home-lang/home/issues/66).
