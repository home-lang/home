# §3.A follow-up — diag-arena/interner heap-state leak: bisection report

**Investigation date:** 2026-05-14
**Worktree:** `agent-aa09a455338a982d3` (base commit `77c89a4d fix(ts-parity): tighten exact directive diagnostics`)
**Status:** **Could not reproduce.** The leak documented in the source NOTE block at `packages/ts_conformance/src/ts_conformance.zig:2844` and in the journal entry "2026-05-14 — Phase 6 §6.A.4 follow-up: shared `HOME_TS_CONFORMANCE_ROOT` path discovery" no longer manifests on this branch.

## Reproduction harness

Re-added an opt-in always-on test `conformance: bisect exact-baseline heap leak` placed BEFORE the adjacent unit tests it was claimed to corrupt (Zig executes tests in declaration order, so only a leading bisect can affect later tests). Toggle with `HOME_TS_CONFORMANCE_BISECT=1`; tune the slice with `HOME_TS_CONFORMANCE_BISECT_{START,LIMIT}` (defaults: START=0, LIMIT=25).

Source: `packages/ts_conformance/src/ts_conformance.zig:2421`

## Bisection log

All runs use `HOME_TS_CONFORMANCE_BISECT=1` plus the listed LIMIT. Adjacent tests checked: `conformance: type-error decl fails as expected` (line 2497) and `conformance: runCorpus supports exact diagnostic entries` (line 2621). All test counts are out of 45/45.

| LIMIT | Outcome | Wall time | Notes |
|------:|---------|----------:|-------|
|    25 | 45/45 PASS | 30 s | First 25 cases all in `directives/` + `moduleResolution/` |
|    50 | 45/45 PASS | 29 s | Adds more `moduleResolution/` cases |
|   100 | 45/45 PASS | 31 s | |
|   200 | 45/45 PASS | 39 s | Reaches `expressions/thisType/...` cases |
|   500 | 45/45 PASS | 60 s | Crosses into `types/`, `expressions/` heavily |
|  1000 | 45/45 PASS | 2 m  | Crosses into `decorators/` |
|  2000 | 45/45 PASS | 3 m  | Spans most of conformance |

`HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1 HOME_TS_CONFORMANCE_LIMIT=50` also runs cleanly to completion (45/45). No `expected 1, found 0` or `expected .passed, found .failed` failures observed in any configuration.

## Hypothesis: the leak was already fixed

The journal entry that documented the leak landed at HEAD `e46d293` (or thereabouts) on 2026-05-14. The current worktree base is six commits ahead at `77c89a4d`. Two of those intervening commits touch `packages/ts_checker/src/check.zig` in ways that look directly relevant:

- **`f84d9ad0 fix(ts-parity): close conformance tail crashes`** — adds a new reentrancy guard `resolving_exported_type_decls: std.AutoHashMapUnmanaged(NodeId, void)` (check.zig +468 lines). Circular module references could legally mention an exported class/interface before its body was available; nested lookups now fall back to `any` instead of recursively rechecking the same declaration. This is a strong candidate for the cross-test corruption: a recursion that escaped the `Checker` instance lifetime would write into the diag arena / interner of a re-entrant invocation.
- **`dca93374 perf(ts-parity): clear full corpus coarse gate`** — additional check.zig changes (+42 lines); commit message claims it cleared the coarse gate to 100%, suggesting it removed a class of late-tail crashes.

Neither commit directly mentions the heap-state interaction, but the timing and the surface area lines up.

## Suggested next steps for the fix agent

1. **Don't chase a fixture that no longer breaks.** Confirm independently on a clean build (`zig build test -Dfilter=ts_conformance --summary all` — should report 45/45 in ~30 s) that the leak is truly gone.
2. **Re-run the bisect harness** (`HOME_TS_CONFORMANCE_BISECT=1 HOME_TS_CONFORMANCE_BISECT_LIMIT=2000 zig build test -Dfilter=ts_conformance`) before declaring the §3.A follow-up closed. If it stays green, retire the NOTE block at `ts_conformance.zig:2844` and the §3.A entry in `TS_PARITY_PLAN.md`.
3. **If it surfaces again**, the bisect harness is already wired to print `[bisect] RUN <idx> <name>` for each case — read backwards from the first crashing adjacent test to find the offender. The most likely re-introduction vectors are: (a) new code in `check.zig` that mutates `Checker`-owned state past the `Compilation.deinit()` boundary, (b) interner-shard work in `interner.zig` (currently dirty in the main repo with broken references to `shardIndexFor` / `Shard`) being merged without finishing the API, or (c) any helper that returns slices borrowed from a per-`Checker` arena into a static / cross-test cache.
4. **Promote the bisect to always-on** once a couple more PRs land cleanly. The opt-in gate (`if (!envBoolOne("HOME_TS_CONFORMANCE_BISECT")) return;`) is the single line to remove. Recommended default LIMIT for an always-on gate: 25 — that's the original threshold that was claimed to corrupt and is short enough to keep CI under 30 s.
