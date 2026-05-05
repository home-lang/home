# bench/vs_tsgo

Cross-compiler benchmark harness: `tsc` (Node-based) vs. `tsgo` (Go) vs.
`home tsc` (Zig).

Per [`docs/TS_PARITY_PLAN.md`](../../docs/TS_PARITY_PLAN.md) §0 Phase 0.6
and §6.4. The numbers in [§0 of the plan](../../docs/TS_PARITY_PLAN.md#0--executive-summary)
are reproducible from this harness.

## Quick start

```sh
# 1. Install hyperfine + dependencies
brew install hyperfine          # or: cargo install hyperfine
npm i -g typescript@5.6         # tsc
brew install typescript-go      # tsgo (or: gh release download from microsoft/typescript-go)

# 2. Materialize the corpus (downloads VS Code, TS repo, etc. at pinned SHAs)
./run.sh corpus

# 3. Run the cold-typecheck suite
./run.sh cold

# 4. Run the watch-rebuild suite
./run.sh watch

# 5. Render a Markdown report from the results JSON
python3 compare.py results/ > results/report.md
```

## Layout

| Path | Purpose |
|---|---|
| `run.sh` | Driver — corpus materialization + benchmark launchers |
| `compare.py` | Reads hyperfine JSON, renders the report.md template |
| `corpus.toml` | Pinned SHAs of the workloads we benchmark against |
| `corpus/` | Materialized corpus (gitignored) |
| `results/` | Per-run hyperfine JSON + rendered report |
| `Dockerfile` | Reproducible env for CI runs (matches `runs-on: ubuntu-latest`) |

## Corpus

The pinned workloads are listed in `corpus.toml`. Roughly:

| Workload | LOC | Why it matters |
|---|---|---|
| TypeScript repo (`microsoft/typescript`) | ~400K | Large, well-known TS codebase |
| VS Code (`microsoft/vscode`) | ~1.5M | The reference "big TS project" |
| Twenty CRM (`twentyhq/twenty`) | ~250K | NestJS, decorator-heavy — tsgo regresses 2× here |
| Playwright (`microsoft/playwright`) | ~150K | Library + tooling mix |
| `ts-toolbelt` consumer | ~10K | Type-meta-programming stress test |

## Metrics

Each run records, per workload, per compiler:

- **Cold typecheck wall-clock** (`hyperfine --warmup 1 --runs 5`).
- **Time-to-first-diagnostic** (Home only — others don't stream).
- **Peak RSS** (`/usr/bin/time -l` on macOS, `time -v` on Linux).
- **Watch incremental rebuild** (driven by `tests/watch/edit.sh` —
  appends a no-op line to a hot file, awaits new diagnostic).

Results land in `results/<timestamp>/<workload>-<compiler>.json`.

## CI integration

The `bench-nightly` GitHub Action runs `./run.sh cold` on a self-hosted
runner (variance reasons) and posts the rendered Markdown report to the
nightly results dashboard at `bench.home-lang.dev`.

## Status

This is **Phase 0.6 skeleton** — the harness layout, the corpus pinning
file, the runner script, and the report template are in place but the
runner currently shells out to whichever `home` binary is on `$PATH`,
which today does not yet implement `home tsc`. The harness becomes
real once Phase 1 lands the TS frontend and Phase 4 lands JS emit.
Until then, `./run.sh` runs against `tsc` and `tsgo` only and reports
the deltas; the `home` column is left empty.
