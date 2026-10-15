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

The corrected-rule snapshot contains **1,182 manifests with check scripts,
1,453 scripts, 1,391 literal compiler segments and 2,494 configs**. It retains
92 scripts requiring review, 55 errors and 1,480 symlink directories. The
corrected rule adds nine manifest paths under the pantry project and its
existing worktrees compared with the contemporaneous scan. Other differences
from earlier snapshots reflect filesystem changes. The report still records
`replacement_verified: false`; the inventory establishes coverage, not
compiler compatibility.

A further 2026-10-13 refresh contains **1,366 manifests with check scripts,
1,678 scripts, 1,615 literal compiler segments and 2,741 configs**. It retains
99 scripts requiring review, 55 invalid fixture manifests and 1,894 symlink
directories. Compared with the corrected-rule snapshot, 387 manifest paths
were added and 203 disappeared. A freshness check also found 115 changed
manifests and four changed configs among the previously recorded paths.
Discovery and pruning rules remain unchanged; the latest report supersedes
the earlier path inventory, and still marks replacement unverified.

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

In this retained run, the real table project remained **unqualified**. Its
reference returned zero; Home exited through the memory guard (125), at a
measured tree footprint of 3,938 MB. All 307 input hashes stayed unchanged during
that run. Profiling reached source checking and showed substantial recursive
generic expansion in Bun's socket interfaces. The storage and identity
corrections did not establish replacement compatibility for that project or
the whole local tree.

The [retained source-owner and storage evidence](../../bench/vs_tsgo/evidence/20261012-local-tsc-owner-storage-controls.tar.gz)
contains the failing diamond reproduction, successful module and CLI controls,
source/image hashes, payload checksums and a redacted real-project outcome.

## Qualified namespace and production-build controls

Cross-file namespace generics previously lost their argument types or failed
checked-owner transfer. Generic display names now occupy a string field in the
owned definition, distinct from declaration IDs. Checked sources publish
qualified namespace types with their own parameter identities, defaults and
recursive bodies. Dependency discovery records namespace qualifiers, and
annotation recovery recognizes namespaces supplied by other files. The
regressions cover seven cases in both file orders through serial, parallel and
streaming compilation, plus dependent constraints and invalid arity.

Compound type payloads no longer masquerade as object columns. Their consumers
use the proper union/intersection or resolved generic surface. Exact interface
instantiation keys also prevent repeated rebuilding of an unchanged body and
mapper; the socket regression uses 635 types, within its original 1,024 bound.
Mapped variance follows bound indexed reads with the correct polarity.

Production builds exposed a separate cleanup expansion: `checkClassDecl`
generated 217,079 unoptimized LLVM instructions with repeated destructors on
error exits. Grouping 50 temporary owners under one cleanup function reduced
the measured candidate to 41,701 instructions. Allocation-failure controls
cover nested overload lists and transferred maps. The corrected, fully
optimized ReleaseFast image builds in about a minute with a measured peak
process-tree footprint of 2,782 MB. Symbols are stripped; compiler features and
the 3,840 MB guard ceiling remain unchanged.

The current sources pass **4,589 checker, 207 driver, 273 Program and 49 CLI
tests**, plus eight executable stream checks. The final ReleaseFast image passes
**180 automatic-variable comparisons, 50 declaration contracts and 60 recursive
interface observations**. Four cross-file constraint/arity diagnostics match
the reference's full output byte for byte. CLI paths now use the command's
working directory for primary and related diagnostics, summaries and config
locations; owned cached spellings remain valid through watch rounds.

The refreshed table check uses an isolated frozen install with 49 unchanged
project source files and a newly hashed **306-file** dependency graph. The
reference returns zero; Home still exits 125 after the guard observes
**4,332 MB**. All graph hashes remain unchanged. The positive comparison fails,
so the real-project negative control has not run. The project and the whole
local tree remain **unqualified**.

The [2026-10-13 namespace evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-qualified-namespace-controls.tar.gz)
retains the module gates, source/image hashes, synthetic inputs, raw CLI
observations and the redacted failed project outcome. Its SHA-256 is
`0767a0a44663b461158e0080459b20755c1b93733da7a0a56a98164d03a3d358`;
all 1,511 payload hashes were verified.

## Lazy namespace declaration growth controls

Forward function signatures exposed another source of recursive expansion:
lowering an annotation eagerly copied unfinished namespace interfaces. Those
annotations now retain an owned declaration reference and its exact arguments;
member and `keyof` operations materialize the surface they need. A visible
forward type alias also takes precedence over a built-in utility before the
alias cache is populated. Compound flags are checked before reading an
instantiation payload, and key walks snapshot compound member IDs across
recursive interner writes.

The socket fixture with forward `connect` and `listen` signatures previously
exceeded its 180-second test deadline. It now checks in under a second with
**373 types**, below the unchanged 1,024 bound. A separate missing-key control
still reports TS2344. The current candidate passes **4,591 checker, 207 driver,
273 Program and 49 CLI tests**, eight executable stream checks, all 180
automatic-variable comparisons, 50 declaration contracts, 60 recursive
interface observations and the four byte-identical constraint/arity diagnostics.

The isolated table graph now completes within the existing memory ceiling:
Home's measured peak process-tree footprint is **3,358 MB**. The reference
returns zero, while Home returns one with **61 diagnostics**. All 306 graph
hashes and 49 project-source hashes remain unchanged. The positive comparison
still fails, so the real-project negative control remains pending; this result
does not qualify replacement of table or the whole local tree.

The [retained lazy-namespace evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-lazy-namespace-controls.tar.gz)
contains the current module and CLI gates and the redacted project result.
Its SHA-256 is
`242d42e5329b7151151083008024ac13cdc32ca38b4b8d4f8a0dbb98189331a2`;
all 1,508 payload hashes were verified.

The change was revalidated after merging the upstream checked-JavaScript-array
fix: **4,591 checker, 207 driver, 276 Program and 49 CLI tests**, eight stream
checks and the same complete native CLI controls pass on the merged sources.
The table replay still reports 61 Home diagnostics, with a measured peak of
**3,338 MB** and unchanged inputs. The
[merged-main revalidation archive](../../bench/vs_tsgo/evidence/20261013-local-tsc-lazy-namespace-main-revalidation.tar.gz)
has SHA-256
`a2ee38f18508f915c9a1f5c01f2014cddeba3cb1bface01beda64079e55563bd`;
all 1,508 payload hashes were verified. The subsequent syslog-only upstream
commits leave all 64 qualified compiler input hashes unchanged.

## Declaration syntax and grammar controls

Class modifiers now recognize keyword-named properties such as
`readonly delete: (name: string) => void`. A line-separated optional property
named `extends` no longer becomes an accidental conditional-type operand.
Missing property types remain genuine parse errors: `value: ;` now reports
TS1110 at the same position as the reference under either `skipLibCheck` setting.

Ambient generator diagnostics are classified as grammar diagnostics rather
than syntactic parse errors. The driver uses the declaration-file state that
is already known during parsing to apply `skipLibCheck` to grammar diagnostics;
true syntax errors remain visible. The focused driver regression checks both
the suppressed grammar error and a retained malformed declaration.

The candidate passes **902 parser, 4,591 checker, 208 driver, 276 Program and 49
CLI tests**, eight executable stream checks and the existing complete native CLI
controls. Eight direct declaration comparisons match the reference's output
byte for byte; the ambient-generator skip control also passes. The retained
diagnostic matrix includes outstanding differences outside these corrected
contracts rather than treating the entire matrix as qualified.

On the unchanged 306-file table graph, Home-only diagnostics fall from 61 to
**53**, with a measured peak process-tree footprint of **3,448 MB**. The reference
still returns zero and Home returns one. Replacement remains unqualified.

The [declaration-parser evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-declaration-parser-controls.tar.gz)
has SHA-256
`a3939a46a1eb1a5a70a13b6bf2b2960f0474b5a3b000ccdb3d51c55f08899b30`;
all 1,567 payload hashes were verified.

## Declaration diagnostic ownership

Qualified JSDoc parameter paths now participate in JavaScript signature checks
only. TypeScript and declaration-file comments remain documentation; JavaScript
still reports TS8032 for a missing object parent. This uses the actual file mode,
including virtual filename sections used by conformance fixtures.

An unresolved name in a syntactically valid computed type key now carries a
semantic diagnostic classification. `skipLibCheck` suppresses that declaration
error while retaining genuine malformed type syntax. Ambient signature
parameters such as `arguments` and `eval` do not create runtime bindings;
ambient variable bindings and implemented parameters retain strict-mode errors.

The candidate passes **906 parser, 4,591 checker, 209 driver, 276 Program and 49
CLI tests**, eight executable stream checks, and the existing automatic,
declaration and recursive native CLI controls. The new
`test-ts-declaration-diagnostics-cli.py` verifies **26 observations** with exact
locations, codes and exit statuses under both `skipLibCheck` settings.
The checked computed-key path still has an additional name-suggestion error
and remains outside the passing contract. These controls do not qualify whole
projects or the complete `~/Code` tree.

On the unchanged 306-file table graph, these fixes reduce Home-only diagnostics
from 53 to **39**. Peak process-tree footprint is **3,333 MB**, within the
unchanged 3,840 MB limit. Native TypeScript exits zero and Home exits one;
the project remains unqualified and its negative control has not run.

The [diagnostic ownership evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-declaration-ownership-controls.tar.gz)
has SHA-256
`e878fce876eae483f6503fb6b508566c8bdcbdd6adffb7c3412e343ac53d2f87`;
all 1,633 payload hashes were verified.

## Global namespace value ownership

Global namespace values now retain their checked graph before the declaration
owner is published. Program imports relocate that graph instead of treating a
namespace's empty declaration type as a missing global. Namespace declarations
merge within and across owners; nested namespace members merge by declaration
path, while ordinary object-valued exports retain their declared types.

Functions merged with namespaces retain their call signature through the
existing `__call` representation. Classes use their checked static object,
including constructor signatures. Namespace graph construction reuses checked
variable, function and class types, preventing duplicate diagnostics from
checking those declarations again.

Uninitialized class field names no longer create false global dependencies.
Computed class keys and actual object-literal shorthand remain value references.
A namespace containing only types reports TS2708 when used as a value. Native
controls confirm that behavior and retain TS2649 for an empty namespace merged
with a runtime export-assignment target. One old checker expectation was
corrected against the native diagnostic rather than preserving its permissive
behavior.

Untyped namespace variables without initializers intentionally retain an unset
HIR type for automatic-variable analysis. Constructing their exported `any`
surface no longer reruns their implicit-any diagnostic. The complete 180-case
native automatic-variable comparison includes the formerly duplicated TS7005
cases under both strict and loose-null settings.

The final candidate passes **4,592 checker, 209 driver, 283 Program and 49 CLI
tests**, eight executable stream checks, all 180 automatic-variable comparisons,
50 declaration contracts, 88 recursive/namespace observations and 26 diagnostic
ownership observations. All 68 compiler and validation input hashes remained
unchanged throughout these gates.

The original isolated global namespace smoke test now passes. On the unchanged
306-file table graph, native TypeScript still exits zero and Home still exits
one with **39** differences. Peak process-tree footprint is **3,668 MB**, within
the unchanged 3,840 MB limit. The planted project negative control has not run.
Global augmentation aliases remain unqualified: a separate imported namespace
aliased inside `declare global` is accepted by native TypeScript but produces
TS2304 in Home. This is the declaration pattern used for the global Bun API.

The [global namespace value evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-global-namespace-value-controls.tar.gz)
has SHA-256
`5458d945512b84a9261bb4efd1edd47d29241243221592f41e2f1afbd581e02e`;
all 1718 payload hashes were verified. Neither this project nor the
complete `~/Code` tree is replacement-qualified.

## Global augmentation aliases

Program's global declaration index now includes the actual `declare global`
scopes of external modules. It excludes ordinary module locals and namespaces
named `global`. Augmentation providers can depend on imported declarations;
those dependencies receive checked owners before an alias is published.

Import-equals namespace aliases retain their module value signatures and their
qualified type definitions. Exported namespace functions and variables travel
through declaration routes with their namespace path, keeping nested exports
separate from a module's top-level members. Entity-name import aliases also
retain namespace meaning in the binder.

The CLI resolver has separate callbacks for queries against a resolved owner
path. Reinterpreting a canonical relative owner path as package text previously
made namespace enumeration fail, replacing an exact shape with an open `any`
index and accepting missing members. Owner-path queries now preserve the exact
export table without changing source-written module resolution.

The qualified annotation recovery check also recognizes an exact retained
global namespace type export. A focused negative control proved that
`Api.Box<number>.value` was correctly instantiated as `number`, then erased to
`any` by the later unresolved-root check. The corrected check preserves that
type and reports TS2322 when it is assigned to `string`.

The bounded supervisor now requests `footprint --noCategories`: it needs the
charged footprint total, not region categorization. The same process headers
are counted once, and auxiliary totals remain excluded. Probe deadlines,
fail-closed behavior, memory limits, and disk floors are unchanged. Existing
parser, stalled-probe cleanup, and all six isolated disk/scanner controls pass.

The optimized augmentation candidate passes all five native comparison suites,
289 Program tests, 50 CLI tests and eight stream checks. The real 306-file
table replay exposed a separate fatal owner-transfer failure, so those controls
do not qualify the real project. A diagnostic build identifies an unfinished
generic definition in the checked owner for Node's `web-globals/fetch.d.ts`:
lowering an unsupported `Options` declaration removes its cache entry but
leaves its reserved definition in the type pool with no body. Importing that
pool correctly rejects it as `InvalidTypeGraph`.

Failed Program definition construction now retires its unpublished reservation
with a complete inert `unknown` body before clearing failed caches. Cleanup
allocates nothing, including when cache insertion fails, and retains allocated
IDs because recursive payloads may already refer to them. A focused regression
checks nested failure, transfer of the resulting pool, and a later supported
retry whose result remains exactly `number`. Transfer still rejects genuinely
unfinished definitions. The corrected Debug table replay timed out after 300
seconds. The corrected optimized build and all five native comparison suites
pass. Its real table replay now completes without the fatal error, with native
TypeScript returning zero and Home returning one with **36** diagnostics.
All 306 graph inputs remain unchanged. Peak process-tree footprint is
**3,048 MB**, within the unchanged 3,840 MB ceiling. The global Bun alias is
recognized, but its `build` export still has an incomplete value surface;
optional indexed reads and other table semantics also remain unqualified.
Full regression validation is pending after two resource-measurement stops.

The next ambient-module candidate retains each string-named module's identity
on its exact value and type declaration routes. Matching imports can resolve
those declarations without a filesystem edge; ordinary file-module lookups
exclude the ambient routes. Global aliases publish generic definitions from
the selected module and construct its runtime namespace from those declarations.
Two ambient modules in one source file retain distinct function signatures.
Named imports retain exact return and generic member types, while a relative
import of the declaration script still reports TS2306.

All **291 Program tests**, the 16 focused native ambient observations and the
expanded **96-observation** tracked augmentation matrix pass on the Debug
candidate. The new cases include incorrect return types, incorrect generic
member assignments, and missing members under both `skipLibCheck` settings.
The remaining module suites, optimized build and real-project replay still
need to qualify this newer candidate. The prior optimized 36-diagnostic table
result above belongs to the reservation-cleanup candidate.

Class-only ambient modules also retain their constructor values and qualified
instance types. Classes now contribute to ambient module existence and exact
type declaration routes. The class correction passes **292 Program tests**,
16 extended class/nested-namespace observations, and all **112** tracked native
augmentation observations. The optimized build passes all five native suites.
The final source passes **4,593 checker, 209 driver, 292 Program and 50 CLI
tests**, eight stream checks, 180 automatic-variable comparisons, 50 declaration
contracts, 88 recursive/namespace observations and 26 diagnostic observations.
All 73 compiler, guard and validation input hashes remained unchanged.

On the unchanged 306-file table graph, the optimized class candidate completes
without `EmitError` and no longer reports a missing Bun `build` export. Native
TypeScript exits zero; Home exits one with **35** remaining diagnostics. No
unexpected outputs were created or removed. Peak guarded footprint is
**3,181 MB**, below the unchanged 3,840 MB ceiling. The table entrypoint and
the complete `~/Code` tree remain unqualified.

Upstream's supervisor now reads physical footprint and process birth identity
through kernel helpers, avoiding the stalled VM traversal and `ps` probes
observed during earlier validation. The existing totals-only `footprint`
fallback remains available. Footprint parsing, process identity/detached-child
cleanup, and stalled-probe deadline controls pass after integration.
All six disk/scanner controls also pass with their simulated-child lock.

The [augmentation and ambient-module evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-global-augmentation-controls.tar.gz)
has SHA-256
`576aed9e83a150b7d30b899097873045c72e0c6898e3069a3ef2c23b912a17c5`;
all 2294 payload hashes were verified. This archive proves the stated compiler
controls and records the still-unqualified table outcome. It does not qualify
other entrypoints, versions, emitted outputs or the complete local project tree.

An isolated `ts-images` replay adds a second real-project memory control. Its
installed native TypeScript reference passes on a 557-file graph. The guarded
Home run reaches **3,955 MB** and is stopped above the unchanged 3,840 MB
ceiling, without producing a complete checker result. All graph inputs and
9,912 staged files remain unchanged, with no unexpected outputs. This
entrypoint remains unqualified; the limit was not raised to make it pass.

## Optional indexed access and mapped property types

Optional indexed reads now retain `undefined` under strict null checking. Exact
member recovery, inference/default recovery and general indexed lookup use the
property's optional metadata. Optional writes retain legacy `undefined`
acceptance unless `exactOptionalPropertyTypes` is enabled. The driver now
propagates that option from tsconfig into checker flags; it was previously
omitted. Homomorphic identity mappings retain declared property types, keeping
optional read widening separate from write types and preserving explicitly
declared `undefined` when removing the optional modifier.

The corrected candidate passes **4,595 checker, 210 driver, 292 Program and 50
CLI tests**, plus all eight stream checks. Debug and stripped ReleaseFast pass
all 48 tracked optional indexed-access observations. The additional Debug
controls match all 48 basic observations and all 30 mapped isolation
observations. The broader 78-observation control retains three known generic
inference differences already present in the published baseline. Additional
generic isolation controls expose return-checking and inferred-result
mismatches; these remain replacement blockers.

ReleaseFast also passes 26 diagnostic ownership observations, 112 global
augmentation observations, 180 automatic-variable comparisons, 50 declaration
observations and 88 recursive-interface observations. Its guarded build peaks
at 2,855 MB. The unchanged 306-file table graph still passes native TypeScript
and fails Home, but Home-only diagnostics decrease from **35 to 32**: three
optional-filter argument errors disappear and no new diagnostic appears. All
graph inputs remain unchanged, with no unexpected output files; the replay
peaks at **3,214 MB**. The table entrypoint remains unqualified.

The [optional indexed-access evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-optional-indexed-controls.tar.gz)
has SHA-256 `1f513b92313e7070f7ea0842151257f7b610f6cae170a0562d5ee4f7f69d5b1b`;
all 2,596 payload hashes were verified. Memory-pressure interruptions, disk-floor
stops, lock-wait expiries and the corrected mapped-write diagnostic regression
are retained alongside final passing gates. The 3,840 MB memory limit and disk
floors are unchanged. These results do not qualify the remaining generic
semantics, ts-images memory failure, other projects, compiler versions,
wrappers, emission, watch/build commands or TypeScript API clients.

## Generic indexed return and result inference

Generic object projections such as `T["value"]` now stay dependent until their
actual arguments are substituted. Lowering them through the object's constraint
previously lost concrete call-result types and allowed unknown results to satisfy
annotations. Indexed return checking now uses the ordinary writing relation for
both generic objects and generic keys. This rejects incompatible dependent
returns while accepting a concrete object whose possible selected properties
all share the returned type. Constrained optional element reads also retain
`undefined`, including when exact optional writes are enabled.

Preserving those types exposed two existing relation gaps: assertion overlap
must inspect an indexed type's base constraint, and assignment to
`NonNullable<T["x"]>` must reject the source when that constraint remains
nullish. Both existing regression expectations match native TypeScript and pass
with the corrected dependent representation.

The final candidate passes **4,597 checker, 210 driver, 292 Program and 50 CLI
tests**, plus eight stream checks. Debug and ReleaseFast match all **124**
return/inference/regression observations and all **32** tracked generic indexed
observations. The tracked regression runs in the Mac/Linux CLI workflow.
ReleaseFast also passes the existing 26 diagnostic, 112 augmentation, 180
automatic-variable comparison, 50 declaration, 88 recursive-interface and 48
optional-indexed gates. The optimized build peaks at **2,814 MB**, below the
unchanged 3,840 MB ceiling.

The unchanged 306-file table graph still has **32** Home-only diagnostics,
with no additions or removals. Native TypeScript passes, Home exits one, all
inputs remain unchanged, and the replay peaks at **3,201 MB**. This project
remains unqualified. Other generic features and the complete project tree still
require qualification; these controls replace the previously recorded failures
only within their actual tested scope.

The [generic indexed-access evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-generic-indexed-controls.tar.gz)
has SHA-256 `3baafa1219a4568568567a20a8f48499546b890bdbbd7c3c9f8bd5c75e661e5c`;
all 2,639 payload hashes were verified. The archive retains initial failures,
corrected regression controls, final passing gates, disk interruptions and
lock-wait expiries. The disk floors and memory limit remain unchanged.

## Imported inherited generic callable types

Callable schema transfer now retains a supported intersection's concrete sibling
members instead of replacing the whole type with its base's contextual read
projection. This preserves an inherited generic interface's own fields across
imports and re-exports. Inference also expands retained generic declaration
edges under a recursion guard before matching their structural members.
Property diagnostics combine exact object constituents, preserving duplicate
members' intersected types and requiredness. Contradictory discriminants now
point to the property while retaining the original intersection's reduction
chain; private conflicts continue through the existing diagnostic path.

The final sources pass **4,597 checker, 210 driver, 294 Program and 50 CLI tests**
and eight stream checks. Debug and ReleaseFast each match **32** table-shaped
observations and **56** tracked imported-generic observations. The latter cover
inherited and own fields, explicit and inferred arguments, returned row types,
re-exports, both optional-property modes and invalid inputs. Their CLI workflow
retains both engines' codes, locations, statuses, input hashes and raw output.
Diagnostic prose remains a separate compatibility requirement.

ReleaseFast also passes 32 generic-indexed, 48 optional-indexed, 88 recursive,
360 automatic-variable and 50 declaration/output observations. The unchanged
**306-file** table graph passes native TypeScript but still fails Home: its
Home-only diagnostics fall from **32 to 24**, with eight false TS2353 property
errors removed and none added. All inputs and the project output set remain
unchanged. This entrypoint and the complete local project tree remain unqualified;
the outstanding table errors, ts-images memory growth, other compiler versions,
wrappers and API uses still need investigation.

The [imported-generic evidence](../../bench/vs_tsgo/evidence/20261013-local-tsc-imported-generic-controls.tar.gz)
has SHA-256 `5e6bf14fdb42356cba59526701074da299f13f85a3f53d53f2758eb71103b011`; all 2,880 payload hashes were
verified. Initial failures, corrected diagnostic regressions, interrupted builds
and final passing gates are retained. The 3,840 MB ceiling and disk floors are
unchanged.

The rebase changed only resource-probe reporting among the recorded candidate
inputs. All 72 compiler build/test inputs stayed identical. The 56 imported
controls pass through the updated guard; its probe cleanup test and six isolated
disk controls also pass. The archive retains the lock-contention observations
and subsequent passing controls.

## Optional object writes and structured array diagnostics

Optional property writes now use one rule across object-literal relations and
property diagnostics: legacy mode permits `undefined`; exact optional mode
retains the declared type. The relation engine receives the exact optional flag,
so typed object assignments obey it too. Exact-only failures use the enclosing
TS2375, TS2379 or TS1360 diagnostic. Other invalid fields retain their property
errors, and the older literal-undefined path avoids duplicate diagnostics.

Array relations now reject incompatible concrete object elements even when the
target has only optional fields. Object-element mismatches belong to the whole
array's declaration, argument or return diagnostic. This fixes both silent
invalid returns and incorrect element-level error locations.

The final sources pass **4,598 checker, 210 driver, 294 Program and 50 CLI tests**
and eight stream checks. Debug and ReleaseFast each pass **128** tracked
observations covering local/imported returns, async returns, variable and typed
assignments, calls, satisfies expressions, nested objects, arrays, generic call
results, mixed invalid fields, concrete numbers, omitted properties and explicit
undefined types in both optional modes. The archive retains the invalid original
async fixture; a corrected fixture supplies Promise/PromiseLike globals and
uses ESNext. Only valid fixtures contribute to the final passing contract.

ReleaseFast also passes 56 imported-generic, 32 generic-indexed, 48 optional-indexed,
88 recursive, 360 automatic-variable and 50 declaration/output observations.
All seven suites pass locally through the pinned TypeScript package's executable
`bin/tsc` entry point. The workflow now uses that executable for every reference
invocation; direct subprocess callers could not execute the package's non-executable
`lib/tsc.js`. GitHub reports the workflow active, but no execution was recorded;
these are local validations and workflow wiring, not a remote green run.

The unchanged **306-file** table graph passes native TypeScript but still fails
Home. Home-only diagnostics fall from **24 to 17**, with seven false optional-return
errors removed and none added. Inputs and the project output set stay unchanged.
The optimized build peaks at **2,760 MB** and the final replay at **3,144 MB**,
below the unchanged 3,840 MB ceiling. This entrypoint and the complete local
project tree remain unqualified; remaining table errors, ts-images memory growth,
other configurations, versions, wrappers and API uses still require evidence.

The [optional-object evidence](../../bench/vs_tsgo/evidence/20261014-local-tsc-optional-object-controls.tar.gz)
has SHA-256 `0b68bba3adc732e0972917e83bb4f995359481b9cd978cc5820bbca6bf30bf40`; all 5,786 payload hashes were verified. Initial
failures, diagnostic regressions, corrected fixtures, complete gates, both reference
entry points and the real-project observations are retained. Diagnostic prose
outside the asserted contracts remains a separate qualification requirement.

## Library arrays, dictionary inference and collation

`toSorted` now contextually types comparator parameters, returns a mutable array
for readonly receivers, and observes the ES2023 library boundary. Older mutable
arrays receive TS2550; readonly and union receivers receive TS2339, with implicit
callback parameter diagnostics retained when the method is unavailable.

`Object.entries` retains generic dictionary values and fixed tuple positions.
Anonymous object properties contribute their combined value types to dictionary
inference. Interfaces and classes require explicit index signatures, except for
TypeScript's `any` dictionary exception. Declaration metadata survives checked
source transfer, imports and substitution. Generic interface schemas retain their
interface origin, and the relation pointer follows transferred metadata storage.

`localeCompare` accepts Intl options with closed value domains. Primitive member
calls collect overloads, and incompatible object properties elaborate TS2769 at
the offending property key.

The sources pass **4,599 checker, 210 driver, 294 Program and 50 CLI tests** and
eight stream checks. Debug and ReleaseFast each pass **64** library observations.
ReleaseFast also passes the existing 128 optional-object, 56 imported-generic,
32 generic-indexed, 48 optional-indexed, 88 recursive, 360 automatic-variable and
50 declaration observations. All eight contracts pass through the executable
TypeScript package wrapper. An initial reference-wrapper timeout was retained;
the fresh-output retry passed.

Native TypeScript passes the unchanged **306-file** table graph. Both Home Debug
and ReleaseFast reached the replay's 300-second deadline, so no diagnostic delta
or replacement qualification is claimed. Project inputs remain unchanged. The
optimized validation guard peaked at **2,824 MB**; the timed-out optimized replay
peaked at **3,217 MB**, below the unchanged 3,840 MB ceiling. Process-probe timeouts
under machine load are retained in the logs. Further project runtime investigation
and the broader local-project qualification remain required.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-library-array-controls.tar.gz`
contains **5,664** verified payloads, with SHA-256
`55132af9f041213dcfc88c0e3ad84763e00521e1da9a4abcaf9392691bdedaab`.
Only synthetic fixtures, hashes, logs and replay scripts are included; real-project
sources are excluded. Cleanup reclaimed **1,577,299,048 bytes** from inactive
regenerable objects in this task's dedicated Zig cache.

## Shared class declaration graphs

Runtime samples identified repeated class-schema construction before checking:
each exported class rebuilt its inherited and referenced declaration graph.
Class collection now uses one builder per bound source snapshot. Export aliases
retain separate schema views sharing declaration identities. A reference-counted
arena remains alive after collection until the last view is released; the
regression verifies graph reuse, inheritance and release order.

The candidate passes **4,599 checker, 210 driver, 295 Program and 50 CLI tests**
and eight stream checks. Debug and ReleaseFast pass the 64 library observations;
ReleaseFast passes the seven existing CLI contracts too. All eight suites also
pass through TypeScript's executable package wrapper. Two full-suite attempts
were stopped by failed resource probes under load; the unchanged-limit third
attempt passed. Those interrupted logs remain in the evidence.

The optimized replay now completes within the unchanged 300-second deadline.
Native TypeScript passes the unchanged **306-file** table graph; Home reports
**12** diagnostics, down from **17**, with five removed and none added. All
inputs and the project output set remain unchanged. The preceding debug replay
still timed out. Guard peaks were **2,788 MB** for optimized validation,
**3,203 MB** for the completed table replay and **2,191 MB** for the final
compiler suites, below the unchanged 3,840 MB ceiling.

The table project remains unqualified. Its remaining failures involve optional
object inference, array relations, callback context and unique-symbol computed
members. Simple isolated array controls pass, so richer declaration/inference
paths require investigation. This evidence does not qualify the complete
`~/Code/**` project tree.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-schema-sharing-controls.tar.gz`
contains **5,519** verified payloads, with SHA-256
`d3a19745853b65cee71d4ef883c15cd37614a21f2c8c3ded7c47ea7e218e81a1`.
The archive retains synthetic contracts, sampled stacks, hashes, logs and replay
scripts; real-project sources are excluded.

## Contextual index parameters and declaration grammar

The three remaining Node declaration errors came from valid `[symbol: string]`
index signatures, rather than unique-symbol members. The shared index-signature
parser now accepts contextual keyword parameter names and preserves their key
and value metadata in interfaces, type literals and classes. Computed-key
TS1169/TS1170 checks now carry grammar classification, so `skipLibCheck` suppresses
them in declarations while true syntax errors remain visible.

The sources pass **907 parser, 4,599 checker, 211 driver, 295 Program and 50 CLI
tests**, plus eight stream checks. Debug and ReleaseFast each pass **56** tracked
declaration-index observations, including contextual names, typed reads, invalid
assignments, computed keys and syntax errors with `skipLibCheck` enabled and
disabled. The eight existing CLI suites pass too, and all nine suites pass
through the executable TypeScript package wrapper. The initial optimized
contract runner was stopped by resource-probe failures under load; its completed
suites and the successful fresh-output continuation are retained.

Native TypeScript passes the unchanged **306-file** table graph. Home diagnostics
fall from **12 to 9**, removing all three false TS1169 index-signature errors and
adding none. Project inputs and output files remain unchanged. Guard peaks are
**3,160 MB** for the replay and **2,274 MB** for the final compiler suites, below
the unchanged 3,840 MB ceiling. The remaining nine application inference and
callback errors keep this project unqualified, and the complete `~/Code/**`
replacement goal remains open.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-contextual-index-controls.tar.gz`
contains **6,285** verified payloads, with SHA-256
`af4147571db098220163720b277210ecc3bcba0324ece82f9047b889b4c77775`.
Synthetic contracts, hashes, logs and replay scripts are included; real-project
sources are excluded. Cleanup reclaimed **1,080,840,560 bytes** of inactive
regenerable objects while preserving the running test binary.

## Resolver realpath allocation ownership

The real filesystem adapter erased the sentinel type returned by Zig's
`realPathFileAlloc`, exposing a buffer of length N backed by an N+1 allocation.
Resolver callers correctly freed the ordinary slice but supplied the wrong
allocation size. The adapter now frees the sentinel allocation with its original
type and returns an ordinary owned copy. A real-filesystem regression fails
against the previous adapter with an allocator mismatch and passes with the fix;
all 51 CLI tests pass.

Installed-library discovery remains unpublished. Synthetic Program coverage
passed 299 tests, but full TypeScript 7 DOM loading exposed a ReleaseFast crash,
Debug timeouts and memory-bound stops. Samples locate substantial work in global
owner transfer and generic-interface predecessor backpatching. These results do
not qualify the table project or the complete local-project replacement goal.
The discovery patch and diagnostic logs remain in the local ignored evidence
directory for continued root-cause work.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-realpath-ownership.tar.gz` contains three verified logs, SHA-256
`4dbb3b92c85998dc6139d06af1e116bebcdb6000abb5f2de8cc92e0f7bbfefd6`. Final CLI test guard peak: 2,124 MB.

## Interface recheck predecessor cycles

A diagnostic DOM replay proved a two-node predecessor cycle while rechecking
`BaseAudioContext`: an earlier declaration was linked back to a later sibling
that already pointed to it. Predecessor insertion now follows source order, and
an earlier recheck preserves the latest same-scope declaration marker. Generic
and nongeneric regressions verify acyclic chains and retained merged members.
The reduced case fails before the fix; all **4,601 checker tests** pass afterward.
The final isolated run peaks at **2,151 MB** under the unchanged 3,840 MB guard.

Full installed-library loading remains unqualified: the stripped DOM replay still
crashes, and its traced Debug counterpart times out after 180 seconds. Discovery
remains unpublished while that separate blocker is investigated. One validation
run stopped at the 512 MB disk floor; cleanup removed **1,849,107,248 bytes** of
inactive generated cache objects after checking process and open-file references.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-interface-recheck-cycle.tar.gz` contains eight
verified payloads, SHA-256
`d6506c2b30611fed8a8aae6b80b5a0ac032c7652907732b88f9835fd62df2f87`.

## Aggregate display input ownership

A symbolic debugger replay located the full-DOM crash in `allocSimpleTypeName`: a
union member slice became stale when recursive callable rendering interned new
union types. Union and intersection renderers now own their member snapshots
across recursive display calls. Both regressions fail before their fixes, force
backing-buffer relocation, and verify that both callable displays survive.
All **4,603 checker tests** pass, including an isolated final run that peaks at
**2,283 MB** under the unchanged 3,840 MB ceiling.

The optimized compiler builds successfully, but the full-DOM comparison still
exceeds the memory ceiling (**4,091 MB** observed before termination). A later
symbolic sample identifies eager structural alias-display expansion during
generic substitution as the next investigation target. Library discovery stays
unpublished, and neither the table project nor the complete local replacement
goal is qualified by these results.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-aggregate-display-ownership.tar.gz` contains
ten verified payloads, SHA-256
`1e51c90c4b7b3506f76f05fd1fff8c46b40aab7f5bd83b68d0c2c159b08768db`. Debug diagnostic builds temporarily disabled allocator stack capture
to obtain symbolic traces; the production allocator configuration is unchanged.

## Alias argument identity and anonymous display ownership

Alias-display substitution bypassed the complete mapper-independence proof used
by ordinary substitution. An unrelated recursive argument could therefore be
rebuilt and structurally rendered. The no-cycle path now uses the same complete
proof, preserving unaffected identity while still substituting dependent
arguments. A regression fails before the fix and verifies both unchanged
`Box<Concrete>` arguments and the required `Box<number>` update.

A new symbolic DOM replay then identified stale anonymous-object members during
recursive generic-signature display. That renderer now owns its member snapshot.
Its forced-relocation regression fails before the fix and passes afterward. A
signature-parameter control passes unchanged because parameters use a separate
pool. All **4,606 checker tests** pass, including an isolated final run peaking
at **2,279 MB** under the unchanged 3,840 MB ceiling.

The optimized compiler builds, but full DOM checking still exceeds the guard
(**3,983 MB** observed). Discovery remains unpublished, and the complete local
replacement goal remains open. Diagnostic allocator settings used for symbolic
traces are restored before publication.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-object-display-identity.tar.gz` contains
twelve verified payloads, SHA-256
`a270452bd1a4d0e47bf173486d6899cbf6cee49d51ffdd876af2c9c7ee080287`.

## Substituted interface display provenance

Substitution retained interface declaration identity but lost its display name:
`Item<T>` became `{ value: number; }` after mapping T to number. The checker now
retains display-only names and argument IDs and renders them on demand. Existing
named and alias displays take precedence, preserving `NumberToNumber` diagnostics.
The metadata does not authorize semantic member refresh and survives checked
ownership transfer with remapped type and string IDs. Capture and transfer
allocation-failure tests cover its owned argument slices.

The new regression fails before the fix and verifies `Item<number>` plus a later
`Item<string>` substitution without a local declaration mapping. All **4,607
checker tests** pass in the final isolated run, peaking at **2,275 MB**. The
optimized compiler builds, but the DOM comparison still exceeds the unchanged
3,840 MB ceiling (**4,364 MB** observed). A symbolic sample shows substantial
recursive substitution remains. Library discovery is still unpublished and the
complete replacement goal remains open.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-interface-display-provenance.tar.gz`
contains eleven verified payloads, SHA-256
`20b5fe6b42e0c6b569d13f246d8ff675b7fe76132d1db9f7b35c2a71f9413427`.

## Installed libraries and recursive event-map substitution

Home now discovers the nearest project-installed TypeScript library directory,
including traditional `typescript/lib` and TypeScript 7 native platform packages.
Real paths preserve symlinked dependency ownership. Explicit compiler-host paths
take precedence, references stay within the selected installation, and `noLib`
and `skipDefaultLibCheck` retain their intended behavior.

Full DOM loading exposed needless recursive event-map substitution: the
independence proof rejected every `keyof` and indexed-access node regardless of
its operands. Checking `MessageEventTarget` manufactured about 78,000 types. The
proof now follows those operands, preserving mapper-independent graphs while
still substituting real dependencies. The reduced regression fails before the
fix, preserves the original identity afterward, and checks a dependent operand.

The production compiler passes all eight installed-library observations against
TypeScript 7.0.2, including valid and invalid assignments with explicit and
target-default libraries. Both compilers load identical **63-file and 94-file**
graphs with matching library hashes. The initial combined run peaks at
**2,752 MB**, below the unchanged 3,840 MB guard. All ten Release CLI suites and
nine existing Debug suites pass. The separate Debug full-DOM contract exceeds
its 90-second deadline and is retained as incomplete.

Validation also passes **4,608 checker, 299 Program, 211 driver and 51 CLI tests**,
plus eight stream checks. A native TypeScript watch test exposed a readiness
race: output could appear before watchers were installed. The contract now
waits for watch readiness before editing; both compilers pass the rerun.

The real table graph remains **306 files** with native exit zero, but Home still
exceeds the memory guard (**4,810 MB** observed). Post-stop hashes confirm all
graph inputs and project sources are unchanged. The table project and the
complete local replacement goal remain unqualified. Cleanup removed
**1,333,145,320 bytes** of inactive cache objects and **967,360,416 bytes** of
obsolete generated compiler images after live-process and open-file checks.

Evidence: `bench/vs_tsgo/evidence/20261014-local-tsc-installed-libraries-event-maps.tar.gz` contains
**5,936** verified payloads, SHA-256
`1cfa42cdd3d3c058e8e9f3a4c12f6855aee2ec6aade842b76f5339d64ca0efc5`. Real-project source files are excluded.

## Cached import provenance capacity

Owner imports previously reserved provenance capacity for the entire source
graph even when its identities were already cached. Re-importing the regression
graph doubled the canonical map from 256 to 512 slots without adding types.
The registry now reserves only for absent source origins before the payload
transaction, retaining stale-owner validation and allocation-failure rollback.

All 10 focused owner tests, 212 driver tests and 299 Program tests pass. The
negative control with the old reservation fails at the expected 256-versus-512
capacity assertion. The combined full-suite run peaks at 2,291 MB.

The stripped release trace builds at 2,825 MB. The table replay still exceeds
the unchanged 3,840 MB guard (5,454 MB observed between polls): 31 library
providers complete and 441 owner imports occur before the stop, while the
current provider has about 12,000 types. All 306 input hashes remain unchanged.
This fixes a proven over-allocation; whole-owner metadata transfer still needs
further memory qualification. No table replacement is claimed.

The production release builds at **2,818 MB** and passes all eight installed-library
observations plus 50 declaration/build/watch observations against TypeScript
7.0.2. The combined contract run peaks at **1,582 MB**.

Evidence: `bench/vs_tsgo/evidence/20261015-local-tsc-provenance-capacity.tar.gz`
contains **194** verified payloads, SHA-256
`c6044318fe58ae20a0c39ea53091f0480ea094f1b38b7304d1a1172f3e7f6fd8`.
Real-project sources are excluded.

## Recursive imported namespace diagnostics

A symbolic profile localizes the table memory runaway to eager union display
construction in `Intl.FormattableTemporalObject`. Imported namespace objects
such as `Temporal.PlainDate` lost their qualified diagnostic names and expanded
as structural callables. Recursive signature rendering then allocated over
7 GB of logical live memory before the process guard stopped it. Comparing
libc and the production allocator reproduced the same boundary; allocator
selection alone was not a fix.

Type-name rendering now stops repeated TypeIds on the active display path.
Imported namespace object names also survive in the persistent diagnostic-only
map, including the later exported-class setup that resets temporary program
state. Both regressions fail at their expected assertions without the respective
fixes: excessive recursive display length and a callable shape instead of
`Temporal.PlainDate`. All **4,610 checker tests** pass, peaking at **2,031 MB**.

The symbolic full-graph replay passes Intl and DOM, completing **119 files**
before its 180-second deadline with **1.05 GB** last logged live allocation.
The production compiler builds at **2,780 MB**, but the complete 306-file table
graph still crosses the unchanged 3,840 MB ceiling (**3,851 MB** observed).
All input hashes are unchanged after both stops. The original diagnostic-name
runaway is removed; the table project and whole local replacement remain
unqualified pending further memory and semantic validation.

Integration passes **299 Program, 212 driver and 51 CLI tests**, plus eight
stream checks. All **ten Release CLI suites** pass against TypeScript 7.0.2;
the combined integration/contract run peaks at **2,169 MB**. Final Zig formatting
changes are verified as whitespace-only against the exact tested source.

Evidence: `bench/vs_tsgo/evidence/20261015-local-tsc-recursive-namespace-display.tar.gz`
contains **2,919** verified payloads, SHA-256
`4e42c2b2e81f40830699fca2188c8f0035f16f9c33d0105518a5f0e9c7f15d11`.
Synthetic controls, stack samples and input-integrity summaries are retained;
real-project source files are excluded.

## Declaration owner selection and refreshed project scope

The global-import filter previously imported every checked declaration owner
into every receiving compilation, including unrelated globals. Ordinary
declaration globals now use the existing reference filter. Implicit language
roots retain their owners and augmentations: boxed/array interfaces, async and
iterator types, resource management, JSX, import metadata and decorators.
Global-object reflection remains conservative. The regression verifies required
owners, unused-owner exclusion, array augmentation and `typeof globalThis`;
restoring the old filter fails at the expected unused-owner assertion.

All **300 Program tests** and **ten Release CLI suites** pass. This includes
64 library-array observations, 128 optional-object observations, 88 recursive
interface observations, 180 automatic-variable comparisons and 50 declaration/
build/watch observations. The final eight installed-library observations pass
at **1,299 MB**. Earlier attempts timed out under simulator CPU contention; a
same-fixture control also timed out with the published compiler while the
candidate completed, and the successful gate retained the 90-second case bound.
The production build peaks at **2,718 MB**. Formatting is whitespace-only
relative to the tested source, and the final 4,190-input freeze is unchanged.

The filter removes a demonstrated unnecessary import, but the complete table
graph still exceeds the unchanged memory guard (**3,928 MB** observed). All
306 input hashes remain unchanged. The pre-filter symbolic replay completed
143 files in 360 seconds with about 2 GB last logged live allocation. The
candidate's symbolic build and production sampling later timed out under host
contention without useful samples. Whole-owner transfers still copy complete
payload pools and checked metadata, requiring further memory investigation.
The table project and the complete replacement goal remain unqualified.

The refreshed local inventory contains **1,201 manifests with check scripts,
1,481 scripts, 1,420 literal compiler segments and 2,536 configs**. It retains
91 scripts for review, 1,977 directory symlinks and the same 55 fixture parse
errors. Relative to the preceding scan, 225 manifest paths were added, 390
removed and 130 retained manifests changed. Seven inventory coverage tests pass.
The direct unambiguous segments comprise 1,167 `--noEmit` commands, 30 build
commands and 203 emit/config-dependent commands; discovery qualifies none of
them. The report stays local; only aggregate counts and report identity are
published.

Evidence: `bench/vs_tsgo/evidence/20261015-local-tsc-declaration-owner-filter.tar.gz`
contains **2,903** verified payloads, SHA-256
`c73778975ebd37f63960d3a3a146b8a952820a1efe49de625ea15b48da07e9de`.
Real-project sources and script text are excluded.

## Reachable owner payloads and checked semantics

The symbolic replay isolated continued growth in whole-owner imports: 161 files
completed in 360 seconds with 2.31 GB last logged live allocation. Small consumers
retained around 100,000 types after importing required globals. The importer now
selects the transitive payload and checked-metadata graph for requested types,
names and declarations. Recursive payloads, generic constraints, signatures,
metadata-only dependencies and real declaration provenance stay connected;
unrelated identities remain unmapped. Full-owner imports retain their existing
API and compose with selected imports.

Global variable annotations also select all interface augmentation owners, and
provider ordering checks those dependencies before a consumer that contributes
globals itself. This restores NumberConstructor/ObjectConstructor members from
separate library declarations. Callable interface merges preserve call signatures.
Negative controls fail at the expected same-owner reduction and constructor
augmentation assertions when their respective fixes are removed.

The production build and unchanged 306-input table graph complete under the
unchanged 3,840 MB process guard (combined build/replay peak 2,770 MB). The earlier
selected-import replay alone peaked at 972 MB. Native TypeScript exits zero;
Home exits one with 44 diagnostics: 37 declaration conflicts and seven array,
iterator or callback errors. Input hashes remain unchanged. Completing within
the memory bound does not qualify semantic compatibility; the table project
and the complete local replacement goal remain unqualified.

All **4,616 checker, 213 driver, 302 Program and 51 CLI tests** pass,
as do the eight stream checks and all **ten Release CLI comparison suites**.
Selected registry imports exercise every allocation failure, reject stale
transitive owners and retain canonical identities across selected/full imports.
Metadata selection rejects a different source owner before target mutation.
The combined validation run peaks at **2,228 MB**; all **4,190 frozen inputs**
remain unchanged after negative controls and final validation.

Evidence: `bench/vs_tsgo/evidence/20261015-local-tsc-reachable-owner-transfer.tar.gz`
contains **2,905** verified payloads, SHA-256
`a64a545363f53094cf7eebb7ef6be77130fb2245483154022e8b1d5f48618221`.
Real-project sources and diagnostic text remain local; only aggregate project
outcomes are included.

## Declaration post-pass skip options

Program-level global-variable, interface-member and ambient-export diagnostic
passes now apply the same per-file declaration skip rule as the checker.
`skipLibCheck` suppresses diagnostics in declaration files;
`skipDefaultLibCheck` limits suppression to the default-library directory.
Declarations remain available for cross-file comparisons and application typing.
The regression covers serial/parallel execution, both skip options, application
errors and package declarations outside the default-library directory. Removing
the global-variable post-pass guard fails the expected diagnostic-count assertion.

All **303 Program tests, 51 CLI tests, eight stream checks and ten Release CLI
comparison suites** pass. The 4,190 compiler inputs remain unchanged after the
negative control and final validation. The production build/replay peaks at
**2,831 MB** under the unchanged **3,840 MB** guard.

The unchanged 306-input table project now has **seven** Home-only application
diagnostics, down from 44: two TS2322, one TS2339, two TS7006 and two TS2741.
All 37 declaration conflicts are removed. Native TypeScript exits zero; Home
exits one. Table and whole-tree replacement remain unqualified while array,
iterator and callback compatibility is resolved.

Evidence: `bench/vs_tsgo/evidence/20261015-local-tsc-declaration-postpass.tar.gz`
contains **2,894** verified payloads, SHA-256
`e52b8ca8b2b4b77ac913f9f1c6ca5624aff0ad348d6d5e6330ed3b5e89cd5bf4`.
Final validation peaks at **2,161 MB**. Real-project sources and diagnostic
text are excluded from the archive.

## Negative discriminant comparisons of broad array lengths

The inequality branch of a discriminant comparison removed union constituents
whose broad property merely overlapped the compared literal. Array unions with
`length: number` therefore became `never` after `length === 1` selected its
false branch. Equality retains overlap; inequality now excludes a constituent
only when its entire discriminant type is assignable to the excluded value.
The correction applies to identifier, member-path and intersection narrowing.
The regression fails with two diagnostics when the correction is removed.

All **4,617 checker and 303 Program tests**, plus **ten Release CLI comparison
suites**, pass. The production build/replay peaks at **2,764 MB**, retaining the
unchanged **3,840 MB** guard. All 306 table inputs remain unchanged. The project
now reports **five** Home-only errors, down from seven: two TS2322, two TS2741
and one TS7006. Native TypeScript still exits zero, while Home exits one.
An additional overlapping broad/literal object-discriminant probe exposes a
separate conservative narrowing mismatch and remains unqualified. The table
project and complete local replacement goal remain unqualified.

Evidence: `bench/vs_tsgo/evidence/20261015-local-tsc-negative-discriminant.tar.gz`
contains **2,892** verified payloads, SHA-256
`66f25529b492eb6f866af2a420f6b1ab77f471c8683479a16c6bfaf4cd9d9164`.
Final validation peaks at **2,276 MB**; the 4,190-input source freeze is unchanged.
Real-project source and diagnostic text are excluded.

## Generic index values preserve universal sources

The checker-specific generic index guard rejected `any` and `never` sources
when the target index value was a constrained type parameter. This rejected
`Row[] | any[]` produced by `map.get(key) ?? []` in a generic class. Both
sources now retain their normal assignability. A separate array shortcut no
longer treats an `unknown` source element as universally assignable. Concrete
values and `unknown` still cannot flow into an arbitrary constrained subtype.
The native comparison retains both negative TS2322 diagnostics at identical
locations, while `any[]` and `never[]` are accepted. Separate negative controls
fail the fallback and unknown-source assertions when their fixes are removed.

All **4,619 checker tests, 303 Program tests and ten Release CLI suites** pass.
The production build/replay peaks at **2,790 MB**, retaining the unchanged
**3,840 MB** guard. All 306 table inputs remain unchanged. The table project
now reports **four** Home-only diagnostics: two TS2741, one TS2322 and one
TS7006, down from five. Native TypeScript exits zero; Home exits one.
A small imported alias/contextual-method probe reproduces the remaining
search-method mismatch. Table and whole-tree replacement remain unqualified.

Evidence: `bench/vs_tsgo/evidence/20261015-local-tsc-generic-index-universal.tar.gz`
contains **2,895** verified payloads, SHA-256
`9299f29769727c3a1fb35d071e940928ef36db5a14efebca1809742abab30d59`.
Final validation peaks at **2,168 MB**; the 4,190-input source freeze is unchanged.
Real-project source and diagnostic text are excluded.
