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

### Changed

- Dropped the "88% complete (43/49 tasks)" framing from `docs/ARCHITECTURE.md`
  and similar overclaiming language elsewhere.
- Demoted `*-COMPLETE.md` / `*-IMPLEMENTED.md` milestone reports under
  `docs/internal/` so the work is preserved as internal notes without
  overstating project status to new users.
