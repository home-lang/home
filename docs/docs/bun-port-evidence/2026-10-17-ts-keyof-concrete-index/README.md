# Concrete receiver indexed by a constrained key

This repairs one exact TypeScript conformance mismatch in [#832](https://github.com/home-lang/home/issues/832), under the broader [#66](https://github.com/home-lang/home/issues/66) work. In `keyofAndIndexedAccess.ts`, Home emitted two extra TS7053 diagnostics for `shape[key]` where `K` is constrained to `keyof Shape` or to the literal subset `"width" | "height"`. TypeScript accepts both reads.

The checker now asks its existing indexed-access resolver whether **every** key in the type parameter's constraint is valid for the concrete receiver. If so, it keeps a symbolic `Shape[K]` result; the direct test inspects both result TypeIds to ensure neither silently becomes `any`. If the constraint contains a known missing key, it reports TS2536 instead of silently treating the read as `any`. A direct negative control, `other[key]` where `other` has only `name` but `K extends keyof Shape`, produces TS2536 in installed TypeScript 5.7.3 and in Home. The original fixture and reference baseline are unchanged.

All substantial runs were serial through `run_bounded` with `HOME_RUN_MAX_MB=3840`:

| Gate | Before | After | Peak tree footprint |
| --- | --- | --- | --- |
| Focused checker reduction, valid and invalid keys, Zig 0.17 | 2 unexpected TS7053 and missing TS2536 | 2/2 test targets pass | 1,654 MB |
| Same focused checker reduction, Zig 0.18.0-dev.146 | not run | 2/2 test targets pass | 1,673 MB |
| Thirteen-case neighboring exact window, including `keyofAndIndexedAccess` | 11 pass, 2 fail; this fixture has two extra TS7053 | 12 pass, 1 fail; this fixture passes | 2,053 MB |
| Unfiltered checker suite, Zig 0.17 | not rerun before this change | 4,650/4,650 pass | 2,363 MB |
| Unfiltered Program suite, Zig 0.17 | not rerun before this change | 321/321 pass | 2,168 MB |

The remaining thirteen-case failure is `keyofAndIndexedAccess2.ts`, with one extra TS2345 at line 121. `conditionalTypes1.ts` and the full TypeScript corpus also remain open. Passing a focused fixture is not evidence that the full corpus or Bun suite passes. The source, upstream fixture, and upstream baseline SHA-256 hashes are in [manifest.json](manifest.json).

The changed files pass targeted Pickier and Zig formatting. The prescribed repository-wide `bunx --bun pickier .` was also run under the same guard; it scanned 83,049 files and exited with 1,858 errors and 725 warnings in unrelated sources/fixtures. No `--fix` was applied and this commit does not claim a clean repository-wide lint result.
