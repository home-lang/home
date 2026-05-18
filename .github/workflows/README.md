# GitHub Actions

> **Workflow porting plan:** See [`docs/TS_PARITY_PLAN.md` §12.18][plan] for the full Bun → Home GHA migration matrix (31 Bun workflows + 2 composite actions mapped to Home equivalents).

## Active workflows

### Core CI / release

- [`ci.yml`](./ci.yml) — lint (pickier), typecheck, test, package smoke, fuzz, filesystem + network tests. Runs on `ubuntu-latest`.
- [`release.yml`](./release.yml) — automates release tagging + changelog generation.
- [`conformance-gate.yml`](./conformance-gate.yml) — per-PR delta gate against the local TypeScript conformance corpus; blocks merges that regress the ratchet.
- [`fuzz-nightly.yml`](./fuzz-nightly.yml) — nightly extended-budget fuzzing for lexer + parser (issue #10). PR-level fuzzing lives in `ci.yml`.

### Dependency management

- [`buddy-bot.yml`](./buddy-bot.yml) — Home's renovate equivalent. Opens PRs for dependency updates.
- [`close-stale-bot-prs.yml`](./close-stale-bot-prs.yml) — auto-closes buddy-bot PRs after 90 days of inactivity. Ported from Bun's `close-stale-robobun-prs.yml`.

### Issue / PR hygiene

- [`stale.yml`](./stale.yml) — closes issues/PRs that go stale. Replaces the older probot/stale config at `.github/stale.yml`. Ported from Bun's `stale.yaml`.
- [`on-slop.yml`](./on-slop.yml) — closes PRs labelled `slop`. Ported from Bun's `on-slop.yml`.
- [`auto-label-claude-prs.yml`](./auto-label-claude-prs.yml) — tags PRs whose body contains the Claude Code "Generated with" footer with the `claude` label. Ported from Bun's `auto-label-claude-prs.yml`.

## Pending ports (see `docs/TS_PARITY_PLAN.md §12.18.d`)

**Phase 2** (low-risk, no runtime dependency):

- `auto-close-duplicates.yml` — needs the matching `scripts/auto-close-duplicates.ts` ported (366 lines upstream).
- `auto-assign-types.yml` — needs a Home maintainer to assign to.
- `claude-dedupe-issues.yml`, `claude-find-issues-for-pr.yml` — need the `.claude/commands/dedupe.md` + `find-issues.md` slash commands ported, plus the `ANTHROPIC_API_KEY` secret on the Home repo.
- `test-bump.yml` — adapt to `bumpx`.

**Phase 3** (lint/format consolidation):

- Fold Bun's `format.yml` + `lint.yml` into `ci.yml`. Add `zig-fmt-check` job + autofix.ci integration.
- Land `.github/actions/setup-home/` composite action (mirror Bun's `setup-bun`).

**Phase 4** (post-Phase 12.0.11 native-dep ports, in lockstep):

- `update-{cares,hdrhistogram,highway,libarchive,libdeflate,lolhtml,lshpack,sqlite3,zstd}.yml` — daily upstream-check workflows for each vendored native dep. Each lands the same week as the matching `12.0.11.<letter>` dependency port.
- `update-root-certs.yml` — daily root-cert refresh; lands with §12.6.b (TLS).
- `update-vendor.yml` — umbrella dispatcher for all of the above.

**Phase 5** (post-Phase 12.10, public API surface stable):

- `home-types.yml` — publish `@types/home` on release. Renamed from Bun's `bun-types.yml`.
- `vscode-release.yml` — publish `packages/vscode-home/` to the VSCode marketplace + OpenVSX on tag.

## Bun-specific workflows we intentionally do not port

See `docs/TS_PARITY_PLAN.md §12.18.e` for the rationale. Headlines:

- `cancel-buildkite-on-pr-close.yml` — Home doesn't use BuildKite.
- `comment-lint.yml.disabled`, `labeled.yml.disabled` — disabled upstream.

[plan]: ../../docs/TS_PARITY_PLAN.md
