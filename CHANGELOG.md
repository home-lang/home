# Changelog

All notable changes to Home will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once a stable release is cut.

> Prior to the introduction of this changelog, history was tracked only in
> `git log`. For changes before the first tagged release, please refer to the
> commit history.

## [Unreleased]

### Added

- `CHANGELOG.md` (this file).
- `docs/CAPABILITY_MATRIX.md` and a condensed capability matrix in the README,

  giving an honest view of what is stable, in progress, or not yet started.

- `docs/internal/` for milestone-style implementation reports that previously

  lived at the top level of `docs/` and inside individual packages.

- **Parity status section in README.md.** At-a-glance headline-numbers table

  followed by per-area sub-tables (TypeScript, Bun runtime port, Bun
  compatibility shim, Node.js, LSP, language features, codegen, tooling,
  stdlib). Every percentage is a byte-for-byte or file-count measurement
  against an external baseline — no aspirational targets.

- **Per-feature parity drill-down pages** under `docs/`, modelled after Bun's

  nodejs-apis doc (per-module heading + 🟢/🟡/🔴 badge + inline list of
  missing APIs):
  - `docs/PARITY-TYPESCRIPT.md` — every TypeScript feature with status
    (types, control flow, classes, modules, JSX, emit, diagnostics, LSP).
  - `docs/PARITY-NODE.md` — every `node:*` module.
  - `docs/PARITY-BUN.md` — every `Bun.*` API + the Phase 12.1-12.11
    sub-phase status table.
  - `docs/PARITY-BUN-COMPAT.md` — the seven Tier-0 symbols of
    `packages/compat/` with per-symbol drill-down and Tier-1+ roadmap.

- **`packages/compat/README.md`** — landing page for the `bun` compatibility

  shim, with the Tier-1-symbol workflow documented end-to-end.

- **`scripts/measure-parity.sh`** — regenerates the README headline-numbers

  table from live file counts (`--markdown`), exports raw values for
  scripting (`--values`), or diffs the README against live counts and
  exits non-zero if it has drifted (`--diff`).

- **`packages/runtime/PORT_AUDIT_2026-05-20.md`** — refreshed runtime

  port audit (472 / 1,193 files; +106 since the 2026-05-18 audit
  driven by Phase 12.2 M1-M6 JSC milestones and Phase 12.7 round-10
  `node:*` shims). The 2026-05-18 audit is retained for its Tier 0 /
  Tier 1 file catalogues with a Superseded-by banner.

- **TypeScript-frontend and Runtime/Bun rows in CAPABILITY_MATRIX.md** —

  20 new rows breaking down `home tsc` (conformance modes, emit
  capabilities, LSP wire surface) and `home run` (port progress, JSC
  bring-up, `node:*` substrate, compat shim) into per-capability
  status entries.

### Changed

- Dropped the "88% complete (43/49 tasks)" framing from `docs/ARCHITECTURE.md`

  and similar overclaiming language elsewhere.

- Demoted `*-COMPLETE.md` / `*-IMPLEMENTED.md` milestone reports under

  `docs/internal/` so the work is preserved as internal notes without
  overstating project status to new users.

- **Replaced the top-of-README `## Capability Matrix` table with a one-

  paragraph callout linking to the new parity-status section and
  per-feature drill-down pages. The condensed status table at the top
  of the README had drifted out of sync with the per-area Parity status
  section below; consolidating leaves a single source of truth for each
  area.

- **`packages/runtime/README.md`** — refreshed the status header,

  expanded "What's here today" with the 22 `node:*` files and 95 JSC
  files, flipped the sub-phase status badges (12.2 / 12.3 / 12.7 from
  "blocked" / "not-started" to 🟡 partial), and updated the build
  instructions to mention `scripts/measure-parity.sh`.

- **`docs/CAPABILITY_MATRIX.md`** — bumped arm64 row from "🚧 Partial

  (assembler scaffolding only)" to "🚧 In progress (Path B-lite
  M1-M11 shipped)" to reflect the closed Issue #5.
