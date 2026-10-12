# Local TypeScript replacement qualification

Replacing `tsc` across the local project tree is **not yet qualified**. Passing
compiler unit tests or one library graph cannot establish compatibility for the
other projects, build commands, or compiler API callers.

## Inventory

Generate the inventory without executing package scripts:

```bash
python3 scripts/ts-project-inventory.py \
  --root "$HOME/Code" --output .home-cache/ts-replacement/local-inventory.json
python3 scripts/tests/test-ts-project-inventory.py
```

The inventory walks ignored framework directories, nested packages and test
fixtures. It records manifest/config hashes, exact script text and tokenized
`tsc` arguments. Dependency and generated cache directories are pruned by the
explicit `pruned_names` list. Directory symlinks, indirect wrappers, shell
directory changes, substitutions and unrecognized runners remain work to review.
Unreadable or malformed manifests make the inventory command exit nonzero;
they are retained in `errors`. `replacement_verified` stays false: discovery
does not constitute a compatibility test.

The 2026-10-11 local snapshot contains **2,060 manifests with check scripts,
2,501 scripts, 2,434 literal compiler segments and 3,652 configs**. It retains
128 scripts requiring review and 55 manifest/walk errors, including deliberately
invalid package-manager fixtures. These counts include nested framework copies
and test projects; they are not counts of independent applications or successful
replacements. The local report is retained under `.home-cache`, outside Git,
because other projects' script contents are not publication artifacts.

## Required evidence

For every actual compiler entrypoint, qualification must retain:

1. Its real working directory, arguments, compiler version, effective config,
   root files and resolved import/library graph. Review wrappers and custom
   config filenames referenced by scripts as well as discovered `tsconfig`s.
2. Reference and Home diagnostics, positions, exit statuses and source hashes
   over unchanged projects. Existing project errors must be distinguished from
   Home-only failures; planted negative controls must still be rejected.
3. Actual emitted JavaScript, declarations, maps and build metadata wherever
   the command emits. Check directory structure, inferred API types and
   downstream consumers as well as output names.
4. Build-reference, clean and watch behavior wherever used, including unchanged
   rebuilds, changed dependencies and config revisions.
5. Separate review of tools that import the TypeScript compiler API. Replacing
   an executable does not itself provide that API.

Run emitting commands in isolated project copies. `--noEmit` can still write
incremental build metadata, so it is not sufficient isolation by itself. Retain
timeouts, memory/disk admission failures, missing dependencies and unresolved
entrypoints as incomplete results.

## Declaration-output regression controls

The first concrete output gap reproduces with an ordinary declaration-only
project: the reference emits `types/index.d.ts`, while the pre-fix Home image
also emits JavaScript and generates artifacts from `globals.d.ts`. Local
spell-check and Craft package builds use the affected declaration-only options.

The correction covers option parsing, initial/watch output selection,
declaration inputs, build freshness and actual cleanup of selected outputs,
maps and build metadata. Cleanup uses configured roots, retains outputs from imports outside that list,
and protects source files; it preserves JS owned by another tool when the project emits only
declarations. Build mode uses the same checked declaration renderer as ordinary
compilation, avoiding the optional scanner placeholder's empty success buffer.

Configuration dependency diagnostics now choose the first contributing JSON
key in source order, with the compilerOptions key as a fallback. Configuration
errors return status 2; ordinary type errors under no-emit retain status 1.
The additional negative control caught and rejected an intermediate change
that incorrectly returned 2 for ordinary no-emit errors.

Both Debug and ReleaseFast images pass all **32 reference compiler observations**. The complete
CLI and Program suites pass **80 and 265 tests**; entrypoint and config suites pass **47 and 169 tests**; the final
ReleaseFast image passes the same controls. The first production build
attempt hit the disk guard; testing resumed when space recovered without
changing the safety floors or deleting unrelated artifacts.

A first real-project check remains unqualified: the local table project is
accepted by its installed TypeScript 7.0.2 compiler, while the pre-emission-fix
Home image stops with `compile error: EmitError`. That is an internal failure,
not a passing comparison with zero diagnostics. Two other selected projects
lost their local reference installations during the run and remain untested.
The next graph audit must diagnose the table failure and admit every remaining
entrypoint; the declaration controls do not satisfy that requirement.

The reference-control runner is available with explicit compiler paths:

```bash
HOME_RUN_MAX_MB=3840 perl scripts/run-bounded.pl 300 \
  python3 scripts/tests/test-ts-declaration-cli.py \
  --home zig-out/bin/home-tsc \
  --reference /path/to/typescript/lib/tsc.js \
  --output .home-cache/ts-replacement/declaration-contracts
```

Its scope is declaration/JavaScript artifact selection, declaration content,
type-error preservation, build freshness/clean and watch updates. Build-info
encoding and byte-exact source-map mappings remain separate gates. The local
inventory controls currently pass all six hermetic tests.

The [retained declaration-control evidence](../../bench/vs_tsgo/evidence/20261011-local-tsc-declaration-controls.tar.gz)
contains the complete successful observations, fixture inputs/outputs, module
logs, pre-fix reproduction and rejected diagnostic/cleanup revisions. It
includes payload checksums and native image hashes. No performance measurements
are claimed. The full Pickier scan now completes discovery but reports 1,857
errors and 684 warnings in other repository files; the changed TS config,
README, report and workflow pass their scoped Pickier check.
