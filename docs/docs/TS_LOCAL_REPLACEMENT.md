# Local TypeScript replacement qualification

Replacing `tsc` across the local project tree is **not yet qualified**. Passing
compiler unit tests or one library graph cannot establish compatibility for the
other projects, build commands, or compiler API callers.

The automatic-variable controls added on 2026-10-12 cover unused declarations,
definite and partial assignments, scalar captures, empty-array mutations,
loop backedges, callback and class-field captures, exported bindings and
lexical shadowing. The correction snapshots incoming branch flow before
checking writes, retains array element types as they evolve, and resolves
the binding before deciding whether a reference crosses a capture boundary.
Deferred instance-field and function references do not acquire an immediate
use-before-declaration error merely because the declaration appears later.

`scripts/tests/test-ts-automatic-variable-cli.py` compares 90 isolated sources
in strict and loose-null modes: 180 comparisons and 360 compiler observations.
It retains diagnostic codes and positions, statuses, compiler/input hashes and
raw output. A mismatch, timeout, unexpected output, modified input or emitted
file fails the audit. This checks those diagnostics and flow contracts;
diagnostic prose, emission, other compiler options and real-project/API
compatibility remain separate qualification requirements. The Mac/Linux CLI
workflow runs the audit and retains both compilers' observations.

The final Debug and ReleaseFast images pass all 180 comparisons per image.
The checker suite passes 4,578 tests; Program, driver, CLI, entrypoint,
configuration, stream and builtin-corpus gates also pass. Both images pass
50 declaration/output observations, and ReleaseFast passes the 32 recursive
interface observations. The additional option controls caught an upstream
regression that suppressed JS output and returned the wrong status for an
invalid declaration-only configuration; output selection and source locations
now match the reference controls.

The synthetic inputs, raw observations, compiler versions, source hashes and
test logs are retained in
[the 2026-10-12 evidence archive](../../bench/vs_tsgo/evidence/20261012-local-tsc-automatic-variable-controls.tar.gz).
Its SHA-256 is `00aa448c40f851f392079167514a3cf51e524925e18ce43a13b4a0980d4614cd`;
all 2,655 payload hashes were verified. These results do not qualify the remaining
real projects or their compiler API uses.

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

The refreshed 2026-10-12 snapshot contains **1,009 manifests with check scripts,
1,275 scripts, 1,218 literal compiler segments and 2,325 configs**. It retains
81 scripts requiring review, 55 errors and 2,711 symlink directories requiring
separate review. The walk and pruning rules are unchanged. Comparing path sets
finds 1,087 removed and 36 added manifests; many missing paths are worktrees or
framework copies that no longer exist. This reflects the current filesystem,
not successful replacement or a decision to exclude projects.

The latest scan corrects a coverage gap: a directory with a dependency/cache
name is retained when it is an actual Git checkout or worktree. The old rule
excluded the real `~/Code/pantry` repository. Seven hermetic inventory controls
now cover both Git directories and worktree pointer files, while ordinary
installed dependency/toolchain directories remain pruned. The report records
these exceptions in `included_pruned_name_projects`.

The resulting current snapshot contains **1,182 manifests with check scripts,
1,453 scripts, 1,391 literal compiler segments and 2,494 configs**. It retains
92 scripts requiring review, 55 errors and 1,480 symlink directories. The
corrected rule adds nine manifest paths under the pantry project and its
existing worktrees compared with the contemporaneous scan. Other differences
from earlier snapshots reflect filesystem changes. The report still records
`replacement_verified: false`; the inventory establishes coverage, not
compiler compatibility.

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
key in source order, with the compilerOptions key as a fallback. Exit status
follows selected emission: skipped outputs under no-emit retain status 1,
while errors without skipped emission return status 2. An invalid declaration-only
configuration selects neither JS nor declarations, so it returns 2 even with
no-emit. List-files-only errors return 1. Option errors suppress semantic
diagnostics but do not alone suppress ordinary JS output.
The additional negative control caught and rejected an intermediate change
that incorrectly returned 2 for ordinary no-emit errors.

Both Debug and ReleaseFast images pass all **32 reference compiler observations**. The complete
CLI and Program suites pass **80 and 265 tests**; entrypoint and config suites pass **47 and 169 tests**; the final
ReleaseFast image passes the same controls. The first production build
attempt hit the disk guard; testing resumed when space recovered without
changing the safety floors or deleting unrelated artifacts.

A first real-project check remains unqualified: the local table project is
accepted by its installed TypeScript 7.0.2 compiler, while the baseline
Home image stops with `compile error: EmitError`. That is an internal failure,
not a passing comparison with zero diagnostics. Two other selected projects
lost their local reference installations during the run and remain untested.
The ownership correction below changes the table outcome to a memory-guard
failure: the final ReleaseFast image reaches **3,988 MB**, exceeding the unchanged
3,840 MB ceiling (exit 125), while the reference still exits 0. All 307 recorded
input hashes are unchanged before and after the replay. The table and every
remaining entrypoint still require qualification; the hermetic controls do not
satisfy that requirement.

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
inventory controls currently pass all seven hermetic tests.

The [retained declaration-control evidence](../../bench/vs_tsgo/evidence/20261011-local-tsc-declaration-controls.tar.gz)
contains the complete successful observations, fixture inputs/outputs, module
logs, pre-fix reproduction and rejected diagnostic/cleanup revisions. It
includes payload checksums and native image hashes. No performance measurements
are claimed. The full Pickier scan now completes discovery but reports 1,857
errors and 684 warnings in other repository files; the changed TS config,
README, report and workflow pass their scoped Pickier check.

## Recursive interface ownership controls

The table failure originates in checked-type transfer: recursive nongeneric
interface definitions can still have an unpublished body when their declaration
file is imported. Transfer correctly rejects that incomplete graph. A later
member lookup should not be required to make a checked declaration transferable.

The correction publishes the actual merged interface bodies after file checking
finishes. Intermediate lookups use the current shape without freezing it before
later declaration merges. Interface-only files also enter declaration-owned
recursion handling, and forward references retain the declaration edge rather
than losing a mutually recursive member to `unknown`.
Previously exposed interface shapes follow the same binding's merged body.
Lookup follows the represented merge edges without a fixed sixteen-step cap;
the CLI controls include twenty-four augmentations.

Recursive method graphs also expose a structural-identity cycle. Identity
comparison keeps exact active pairs outside the evicting result cache, checks
the remaining members, and avoids caching successes that depend on an ancestor
comparison that can still fail. The regression includes incompatible leaf
types and a subsequent comparison of the child pair.

Tagged templates and their subsequent member/index accesses remain in the
constructor's callee parse. This keeps nested constructor argument lists at
their correct levels, instead of constructing the tag result before reading
its constructor member.

The CLI runner checks self properties, self methods with and without an alias,
both mutual declaration orders, merged interfaces and nested constructor
signatures. Every valid consumer has a corresponding deliberate assignment
error. It compares diagnostic codes, positions and exit statuses under
`skipLibCheck`, verifies unchanged fixture inputs, and retains partial results
and timeouts as failures:

```bash
HOME_RUN_MAX_MB=3840 perl scripts/run-bounded.pl 300 \
  python3 scripts/tests/test-ts-recursive-interface-cli.py \
  --home zig-out/bin/home-tsc \
  --reference /path/to/typescript/lib/tsc.js \
  --output .home-cache/ts-replacement/recursive-interface-contracts
```

The final ReleaseFast image passes all **32 recursive-interface observations**
and the existing **32 declaration observations**. The Debug module suites pass
**4,570 checker, 268 Program, 201 driver, 908 parser/JSDoc, 80 CLI and 47 entrypoint
tests** (6,074 test executions). The earlier image fails the long merge control,
and the original image also accepts the deliberately wrong nested-constructor
assignment. The final controls preserve the real TS2322 errors and their
positions.

The broader built-in smoke gate currently passes **69 of 71 cases**, including
two failures reproduced independently of this change. Its relative-import case
expects no error despite the missing `./bar`; both the installed reference and
the baseline Home image correctly report TS2307. The other case exposes a
compiler gap: strict-mode `let x;` with no uses is accepted by TypeScript, while
both the baseline and candidate Home images report TS7034. These are retained
as unresolved gates, rather than treating the failed smoke run as a pass.

The [retained recursive-interface evidence](../../bench/vs_tsgo/evidence/20261011-local-tsc-recursive-interface-controls.tar.gz)
contains successful production observations, isolated fixture inputs/outputs,
module logs, rejected intermediate controls, the baseline probes and a redacted
real-project outcome. It includes payload checksums and native/source hashes;
private project inputs remain local. Archive SHA-256:
`6e0f3b9df3b1f4bf67c26a9bb639665cb419e7e0b279d2a2a0cc579b9fb0bdb8`.

## Source identity and demand-sized storage controls

Dependency diamonds previously copied the same declaration-owned types again
when an intermediate source imported them. Import provenance now retains the
original immutable owner revision and TypeId through intermediate pools. Direct,
indirect and repeated imports reuse that identity, while distinct declarations
with equal shapes remain distinct. Publication follows successful checked-type
transfer; failed metadata and allocator operations preserve the previous graph.
Destroying a target pool clears its provenance before its address can be reused.
Tombstoned transitive owners remain invalid even when a destination has cached IDs.

Prepared compilations now use exclusively owned type storage that starts with
primitive headers and grows during checking. The shared interner retains its
existing reserve contract. A 32-file bind-only regression verifies that each
file avoids reserving a million headers before checking, and a separate growth
regression verifies stable IDs through reallocations.

The Debug suites pass **4,579 checker, 271 Program and 207 driver tests**. The
ReleaseFast image passes **180 automatic-variable comparisons** (360 compiler
observations), **50 declaration contracts** and **32 recursive-interface
observations** against the installed reference. The source-owner controls cover
a 16-owner dependency graph, failed metadata, allocation failure, invalidated
revisions and target-address reuse.

The real table project remains **unqualified**. Its reference returns zero;
Home still exits through the memory guard (125), at a measured tree footprint
of 3,938 MB. All 307 input hashes remain unchanged. Profiling now reaches source
checking and shows substantial recursive generic expansion in Bun's socket
interfaces. The storage and identity corrections do not establish replacement
compatibility for that project or the whole local tree.

The [retained source-owner and storage evidence](../../bench/vs_tsgo/evidence/20261012-local-tsc-owner-storage-controls.tar.gz)
contains the failing diamond reproduction, successful module and CLI controls,
source/image hashes, payload checksums and a redacted real-project outcome.
