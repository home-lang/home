# Upstream parity baselines & diff workflow

This is the durable index for the "once we reach parity, diff against the
latest official upstream and plan tasks from that diff" workflow. It records
where Home ported *from* for each upstream, how to compute the live delta, and
how to triage the result.

| Upstream | Pin (where Home ported from) | Pin location | Reference checkout | Diff computable today? |
|---|---|---|---|---|
| **Bun** (engine) | `fd0b6f1a271fca0b8124b69f230b100f4d636af6` | `packages/runtime/UPSTREAM_SHA.txt` (enforced by `scripts/sync-bun-tests.sh`) | `~/Code/bun` | ✅ yes — after `git fetch` |
| **typescript-go** (canonical TypeScript 7 reference) | `b8276f35cd288aa163fad0516b60ddaacec87ee7` | `_submodules/typescript-go` gitlink | `_submodules/typescript-go` | ✅ yes — pinned submodule on `main` |

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

`microsoft/typescript-go` is now Home's repository-owned source of truth for
TypeScript 7 behavior. The gitlink pins tsgo `main` at
`b8276f35cd288aa163fad0516b60ddaacec87ee7`; that revision pins its inherited
TypeScript corpus at `4d4f005c8541e0255a9d8791205fdce326e462bc`.

The 2026-07-16 transition moved tsgo forward 107 commits from the prior local
checkout. Its inherited TypeScript corpus moved forward 23 commits without
changing the 5,907-case expanded conformance inventory or its error baselines.
Home passes all 299 expanded tsgo-native compiler testdata cases exactly and
holds 5,045/5,907 inherited exact cases, with 862 recorded failure identities.

Initialize the reproducible two-level checkout with:

```sh
git submodule update --init --recursive --depth 1
```

The conformance harness uses `_submodules/typescript-go` by default and still
accepts `HOME_TS_CONFORMANCE_ROOT=/path/to/typescript-go` for surveying another
revision. To compute the live native-compiler delta:

```sh
git -C _submodules/typescript-go fetch origin main
git -C _submodules/typescript-go log --oneline HEAD..origin/main
```

The TS **diagnostic-code** lane remains diff-driven: regenerate it with
`node scripts/gen-ts-reachability.mjs` after a tsgo bump, then triage new live
emission sites separately from API, LSP, build, and CI-only changes. The open
compiler frontier remains exact diagnostic parity against tsgo's inherited
conformance baselines.

## Status of the "diff → task list" automation

No generator exists yet. Parity waves triage upstream commits **by hand**
(`docs/TS_PARITY_PLAN.md` wave log). A future `scripts/gen-upstream-tasklist.mjs`
can read both machine pins, run each upstream log range, and classify
compiler-observable changes separately from API, editor, build, and CI noise.
