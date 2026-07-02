# Upstream parity baselines & diff workflow

This is the durable index for the "once we reach parity, diff against the
latest official upstream and plan tasks from that diff" workflow. It records
where Home ported *from* for each upstream, how to compute the live delta, and
how to triage the result.

| Upstream | Pin (where Home ported from) | Pin location | Reference checkout | Diff computable today? |
|---|---|---|---|---|
| **Bun** (engine) | `fd0b6f1a271fca0b8124b69f230b100f4d636af6` | `packages/runtime/UPSTREAM_SHA.txt` (enforced by `scripts/sync-bun-tests.sh`) | `~/Code/bun` | ✅ yes — after `git fetch` |
| **typescript-go** (tsc reference) | `462a1a4f4` (short; w23 wave) | prose only — `docs/TS_PARITY_PLAN.md` parity-wave log | `~/Code/typescript-go` | ❌ no — checkout has **no `.git`**; needs re-clone |

## Bun

**Pin is real and the delta is large — and growing.** As of 2026-07-02,
`~/Code/bun` `origin/main` is at `1498d7b77a`, **634 commits** ahead of the
pinned `fd0b6f1a27` (was 425 on 2026-06-23 — Bun moves ~15 commits/day). The
pin has NOT advanced. Full snapshot + engine-vs-Rust-side triage:
[`BUN_UPSTREAM_DIFF_fd0b6f1a27.md`](./BUN_UPSTREAM_DIFF_fd0b6f1a27.md).

Regenerate the live delta:

```sh
cd ~/Code/bun && git fetch origin
git rev-list --count "$(cat <repo>/packages/runtime/UPSTREAM_SHA.txt)..origin/main"
git log --oneline "$(cat <repo>/packages/runtime/UPSTREAM_SHA.txt)..origin/main"
```

### Triage note: engine vs Rust-side

Home maintains Bun's **engine** (parser, JSC bindings, runtime APIs, node:
modules); Bun has moved package-manager / install / app-build subsystems to
**Rust**, which are *not* Home's port surface. Bucket the diff before planning:

- **Home-relevant (engine):** `node` (18), `sql`/`postgres`/`mysql`/`sql_jsc`
  (21), `parser`/`js_parser` (16), `resolver` (8), `jsc` (7), `fetch` (7),
  `bundler` (6), `fs` (5), `http` (4), `websocket` (3), `crypto` (3),
  `webcore`/`runtime` (4), `zlib` (1), `shell`/`sys` (10).
- **Likely Rust-side / app / noise (skip or low-priority):** `install` (22),
  `css` (19), `ci` (13), `yaml` (10), `test` (11), `build`.

The engine buckets are the candidate task list. `node:http2`, `node:stream`,
`node:fs` were each synced to Node v26.3.0 upstream in this range — large,
self-contained porting targets.

## typescript-go

**Pin is prose-only and the diff is currently impossible to compute on this
machine.** `~/Code/typescript-go` has **no `.git`** (only `_submodules/TypeScript`
survives at `f350b52331`). The baseline `462a1a4f4` is recorded only in the
`docs/TS_PARITY_PLAN.md` w23 parity-wave entry (2026-06-16), not as a machine
pin.

To make the tsgo half runnable:
1. Re-clone `microsoft/typescript-go`, check out `462a1a4f4`, expand to the full
   40-char SHA.
2. Record it as a real pin (mirror the Bun convention).
3. `git log <pin>..origin/main`, then triage compiler-observable diagnostics vs
   codegen/CI noise (the parity waves currently do this by hand).

Note: the TS **diagnostic-code** lane is already diff-driven and at parity —
`node scripts/gen-ts-reachability.mjs` reports active-reachable = 0, so a tsgo
bump only adds work if it introduces new emission sites. The open tsgo frontier
is **type-checker exact-mode conformance** (~71% on the boss dashboard), which is
a grind independent of the upstream diff.

## Status of the "diff → task list" automation

No generator exists yet. Parity waves triage upstream commits **by hand**
(`docs/TS_PARITY_PLAN.md` wave log). A future `scripts/gen-upstream-tasklist.mjs`
could read both pins, run `git log <pin>..origin/main`, and classify commits
engine-observable vs noise — blocked on the tsgo re-clone for the TS half.
