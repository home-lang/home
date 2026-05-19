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

### Changed

- Dropped the "88% complete (43/49 tasks)" framing from `docs/ARCHITECTURE.md`

  and similar overclaiming language elsewhere.

- Demoted `*-COMPLETE.md` / `*-IMPLEMENTED.md` milestone reports under

  `docs/internal/` so the work is preserved as internal notes without
  overstating project status to new users.
