# TypeScript frontend performance

Home maintains a reproducible frontend benchmark for `home-tsc`, TypeScript's
JavaScript implementation (`tsc` 6.x), and stable native TypeScript 7
(`tsgo` in the tables below).
The benchmark measures parse, bind, and type-check work only; all compilers
receive the same valid projects and run with emission disabled.
Ongoing coverage and optimization work is tracked in
[GitHub issue #416](https://github.com/home-lang/home/issues/416).

## Current snapshot

Measured 2026-09-01 at commit `ed8bf949b` on an Apple M3 Pro MacBook Pro
(11 cores, 18 GB RAM, arm64, macOS 27.0). Each value is the mean and sample
standard deviation of 30 new compiler processes after three warmup rounds.
The complete raw-result identifier is `20260901T084835Z`. The runner first
admitted all 20 selected workloads against version-checked TS **6.0.3**, native
TS **7.0.2**, and Home. Native TS 7 and `tsgo` are one competitor. All **600
round files / 1,800 successful finite samples** are retained without filtering.

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `checkjs_jsdoc` | 203.0 ± 2.3 ms | 55.6 ± 6.7 ms | **31.8 ± 0.5 ms** | **1.75× faster** |
| `class_hierarchy` | 187.6 ± 9.4 ms | 53.4 ± 2.1 ms | **24.5 ± 1.2 ms** | **2.18× faster** |
| `commonjs_graph` | 151.2 ± 2.5 ms | 49.1 ± 1.5 ms | **25.5 ± 0.7 ms** | **1.92× faster** |
| `control_flow` | 187.6 ± 3.9 ms | 59.4 ± 2.1 ms | **26.8 ± 0.8 ms** | **2.21× faster** |
| `deep_types` | 126.9 ± 2.6 ms | 52.1 ± 1.0 ms | **23.7 ± 0.6 ms** | **2.20× faster** |
| `destructuring` | 143.1 ± 7.6 ms | 49.8 ± 2.4 ms | **15.9 ± 0.7 ms** | **3.14× faster** |
| `generic_calls` | 174.6 ± 2.0 ms | 54.1 ± 1.3 ms | **18.5 ± 0.4 ms** | **2.92× faster** |
| `import_graph` | 128.5 ± 1.3 ms | 45.8 ± 2.1 ms | **19.4 ± 0.4 ms** | **2.36× faster** |
| `interface_composition` | 201.2 ± 9.4 ms | 63.5 ± 1.7 ms | **38.9 ± 0.7 ms** | **1.63× faster** |
| `many_files` | 204.9 ± 4.3 ms | 54.0 ± 8.0 ms | **20.2 ± 0.6 ms** | **2.67× faster** |
| `null_safe_access` | 192.8 ± 9.5 ms | 58.3 ± 1.4 ms | **32.5 ± 3.0 ms** | **1.79× faster** |
| `overload_resolution` | 205.8 ± 3.6 ms | 67.0 ± 1.5 ms | **25.8 ± 0.5 ms** | **2.60× faster** |
| `recursive_generics` | 152.6 ± 4.6 ms | 73.2 ± 5.7 ms | **14.2 ± 0.4 ms** | **5.16× faster** |
| `reexport_graph` | 95.0 ± 1.6 ms | 41.0 ± 0.7 ms | **19.3 ± 1.4 ms** | **2.12× faster** |
| `startup` | 69.3 ± 27.8 ms | 44.9 ± 20.9 ms | **3.6 ± 1.1 ms** | **12.56× faster** |
| `structural_objects` | 189.9 ± 2.4 ms | 60.2 ± 1.3 ms | **23.9 ± 0.6 ms** | **2.52× faster** |
| `tsx_components` | 159.5 ± 6.6 ms | 47.0 ± 1.5 ms | **19.9 ± 0.3 ms** | **2.36× faster** |
| `type_predicates` | 238.5 ± 9.3 ms | 73.1 ± 4.3 ms | **31.0 ± 2.1 ms** | **2.36× faster** |
| `type_predicates_large` | 1000.4 ± 27.8 ms | 354.9 ± 20.1 ms | **223.8 ± 10.7 ms** | **1.59× faster** |
| `variadic_tuples` | 243.4 ± 4.8 ms | 77.5 ± 5.0 ms | **33.1 ± 1.4 ms** | **2.34× faster** |

Home records lower means on **20/20 admitted workloads** and lower paired times
in **600/600 rounds**. Every row's paired 95% confidence interval for the
fastest-competitor-minus-Home difference is above zero. The narrowest mean
lead is **1.59×** on `type_predicates_large`; this is still not evidence of
universal leadership. These are local
synthetic results; real projects, other platforms, and broader rejection
coverage remain separate validation work. Historical snapshots, including
losses, remain in the checkpoint sections below and are not averaged into this
table.

The comparison column always uses the faster of `tsc` and `tsgo`. Ratios
rounding to `1.00×` are labeled near ties in either direction, not directional
wins. This is a display-resolution rule, not a statistical significance test;
other directional labels also compare means, not certainty. These are local
synthetic measurements, not a claim that every real project or machine has
the same speedup.

### Free-type-parameter root memo (rejected)

The retained profile showed repeated `containsFreeTypeParameter` graph walks in
inference and assignability. The rejected probe memoized completed root-query
results by TypeId. Positive answers are monotonic and were always eligible;
negative answers were cached only when the traversal saw no memberless object,
because an empty object can be a reserved namespace identity whose members are
completed later. Primitive and direct type-parameter fast paths stayed ahead of
the memo lookup. A focused cyclic-graph regression covered cached positive and
negative answers.

The fixed accepted baseline binary is SHA-256
`8bc94b0b9187865ab8ff38a29b1e25a57f8eb9f603453b3177ca5b41ec79f8b0`;
the experimental candidate was
`8d814b9fe6b41ed280a8f7a078861b8d601dc6194f8c1f61e0833c58e324a316`.
The focused regression passed, and baseline and candidate exited zero with
byte-identical empty stdout and stderr on the unchanged official project.

The official screen used three alternating warmup pairs, reversed process
order in every measured pair, and retained every successful finite sample.
Paired intervals are baseline-minus-candidate:

| Official 2,048-family A/B, 10 pairs | Baseline | Candidate | Result | Paired 95% CI |
|---|---:|---:|---:|---:|
| Wall | **216.023 ± 2.201 ms** | 217.643 ± 4.010 ms | 0.9926×; 4/10 candidate wins | -3.836 to +0.372 ms |
| CPU | **214.927 ± 2.140 ms** | 216.599 ± 4.005 ms | 0.9923×; 4/10 candidate wins | -3.795 to +0.246 ms |
| Peak RSS | **75.139 ± 0.060 MiB** | 75.197 ± 0.015 MiB | 0.9992×; 0/10 candidate wins | **-0.094 to -0.022 MiB** |

No repository test workload was active in the starting load snapshot. An
unrelated zig-js regression command appeared by the final snapshot. Every
sample remains in the result; the candidate's higher timing means and 10/10
RSS losses already fail the primary gate without attributing selected rounds
to that late load. The source probe and regression were fully reverted, and no
confirmation, scale run, source commit, or competitor checkpoint was admitted.
Frozen binaries, exact outputs, load snapshots, and all timing rounds are
retained under
`bench/vs_tsgo/results/free-type-parameter-root-memo.20260901T104559Z/`.

### Primitive type-name dispatch (rejected)

The retained profile showed byte equality checks as its hottest leaf, including
the unresolved-signature path's repeated primitive-name chain. The rejected
probe routed those checks through the existing primitive classifier and changed
that classifier to dispatch first by exact byte length and, for six-byte names,
the first byte. It accepted exactly the same twelve lowercase primitive names;
there was no source gate, cache, allocation, result shortcut, or workload
special case.

The fixed accepted baseline binary is SHA-256
`8bc94b0b9187865ab8ff38a29b1e25a57f8eb9f603453b3177ca5b41ec79f8b0`;
the experimental candidate was
`07eae0070563974803b18518db03e29e23052832a256a3d1e8460c6c41d1887d`.
The focused classifier regression, complete ReleaseFast `ts_checker` and TS
driver suites, all **95/95** benchmark-harness tests, `zig fmt --check`, and
`git diff --check` passed. Baseline and candidate exited zero with
byte-identical empty stdout and stderr on the unchanged official project and a
deterministic 32,768-family copy.

Every set used three alternating warmup pairs, reversed process order in every
measured pair, and retained every successful finite sample. Paired intervals
are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 215.440 ± 1.922 ms | **214.456 ± 1.507 ms** | **1.0046×; 6/10 wins** | **+0.170 to +1.824 ms** |
| Official 2,048 families, 10-pair screen | CPU | 214.179 ± 1.879 ms | **213.282 ± 1.398 ms** | **1.0042×; 6/10 wins** | **+0.174 to +1.656 ms** |
| Official 2,048 families, 30-pair confirmation | Wall | 239.333 ± 11.059 ms | **234.229 ± 6.926 ms** | **1.0218×; 20/30 wins** | **+1.983 to +8.664 ms** |
| Official 2,048 families, 30-pair confirmation | CPU | 236.861 ± 7.378 ms | **232.208 ± 6.089 ms** | **1.0200×; 22/30 wins** | **+2.150 to +7.167 ms** |
| Diagnostic 32,768 families, 10 pairs | Wall | 3893.608 ± 78.673 ms | **3883.171 ± 131.193 ms** | 1.0027×; 7/10 wins | -74.299 to +74.560 ms |
| Diagnostic 32,768 families, 10 pairs | CPU | 3883.077 ± 76.470 ms | **3861.250 ± 100.959 ms** | 1.0057×; 7/10 wins | -42.135 to +74.755 ms |

Peak RSS favored the candidate by 0.009 MiB in the screen, 0.008 MiB in the
confirmation, and 0.017 MiB at scale; all three paired RSS intervals were
positive. Timing evidence, rather than RSS alone, controls admission.

The screen overlapped a single unrelated zig-js benchmark at its start. A new
`threadfuzz` shard started between the confirmation preflight and its first
load snapshot, reaching 439.5% CPU; it remained active throughout that set.
The queued fuzz workload had no idle gap, so the scale set ran under its next
stable `broad` mode, which occupied 52.9% CPU at the start. By the end that
shard had exited and unrelated Typesense and macOS services had started. No
sample was filtered, replaced, or selectively rerun.

Although both official sets cleared their gates, both required scale timing
intervals cross zero. The candidate therefore failed the precommitted scale
rule and was fully reverted. No source commit or TypeScript 6.0.3 versus native
TypeScript 7.0.2 competitor checkpoint was admitted. The temporary 50 MB
corpus was moved to Trash after recording exact outputs. Frozen binaries,
load snapshots, and all 50 timing pairs are retained under
`bench/vs_tsgo/results/primitive-type-name-dispatch.20260901T102051Z/`.

### Stable pool-index inference (rejected)

The retained post-reservation profile attributed 19 direct samples in
`inferFromPair` to copying object-member slices. Those copies prevent recursive
inference from retaining a slice across interner growth, because growth can
relocate the backing array. The rejected probe instead copied each current
member value immediately before recursion and re-fetched the next value using
the payload's stable pool offset. It applied the same representation rule to
parameter unions, parameter intersections, argument unions, and parameter
objects; no inference branch, member order, or diagnostic rule changed.

The fixed accepted baseline binary is SHA-256
`8bc94b0b9187865ab8ff38a29b1e25a57f8eb9f603453b3177ca5b41ec79f8b0`;
the experimental candidate was
`9d98cec9ef1b1c8a6928a9ad57c8975d750a2ee21779c2bdbc4e80d0802fee51`.
A focused recursive-inference regression and the complete ReleaseFast
`ts_checker` suite passed. Baseline and candidate also exited zero with
byte-identical empty stdout and stderr on the unchanged official project.

The official screen and independent confirmation each used three alternating
warmup pairs, reversed process order in every measured pair, and retained
every successful finite sample. Paired intervals are
baseline-minus-candidate:

| Official 2,048-family A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| 10-pair screen | Wall | 215.851 ± 2.596 ms | **213.636 ± 2.078 ms** | **1.0104×; 10/10 wins** | **+1.473 to +2.968 ms** |
| 10-pair screen | CPU | 214.688 ± 2.529 ms | **212.560 ± 2.045 ms** | **1.0100×; 10/10 wins** | **+1.484 to +2.824 ms** |
| 30-pair confirmation | Wall | 222.219 ± 13.030 ms | **218.938 ± 8.714 ms** | 1.0150×; 20/30 wins | -1.575 to +8.838 ms |
| 30-pair confirmation | CPU | 219.641 ± 7.267 ms | **217.443 ± 7.563 ms** | 1.0101×; 20/30 wins | -1.203 to +5.471 ms |

Mean peak RSS favored the candidate in both sets. The screen measured 75.086
± 0.008 MiB versus 74.873 ± 0.229 MiB (baseline-minus-candidate interval
+0.084 to +0.341 MiB); confirmation measured 75.085 ± 0.010 MiB versus
74.874 ± 0.216 MiB (interval +0.139 to +0.284 MiB).

The screen began with Spotlight occupying one core and ended with an unrelated
Typesense process also using most of a core. By the confirmation's final load
snapshot, unrelated git, FSEvents, Typesense, and MySQL processes were active.
That activity plausibly widened the timing spread, but no sample was removed,
replaced, or selectively rerun. Because both confirmation timing intervals
cross zero, the candidate failed its precommitted admission rule. The source
probe and regression were fully reverted; no scale run, source commit, or
competitor checkpoint was admitted. Frozen binaries, exact outputs, load
snapshots, and all 40 timing pairs are retained under
`bench/vs_tsgo/results/inference-stable-pool-index.20260901T095901Z/`.

### Broad checker-directive marker gates (rejected)

After rejecting exact directive-marker expansion, a smaller follow-up reused
two broad markers already present in the shared source index. Files without
`@allow` returned before the exact `allowUnreachableCode` searches, and files
without any `@` returned before the exact `noImplicitThis` search. Files that
contained either broad marker retained the original exact substring searches,
so the probe changed neither recognized spellings nor the marker automaton.

The fixed baseline binary is SHA-256
`c4a4d99e5b2c945512519592b0ea905667554224cbbd4a29aad904efd84feab3`;
the candidate is
`47e02a823771540696c07484039213cf8b51668bf4c62f6d94ba0e985bb3042a`.
The complete ReleaseFast checker suite passed, including a focused test that
preserved `noImplicitThis: false` behavior. `zig fmt --check` and
`git diff --check` passed, and both binaries exited zero with byte-identical
empty stdout and stderr on the unchanged official 2,048-family project.

The primary screen used three alternating warmup pairs, reversed process
order in every measured pair, and retained all ten pairs. One unrelated
Typesense process and Spotlight remained active in the recorded load
snapshots. Paired intervals are baseline-minus-candidate:

| Official 2,048-family A/B, 10 pairs | Baseline | Candidate | Result | Paired 95% CI |
|---|---:|---:|---:|---:|
| Wall | **214.961 ± 1.612 ms** | 215.475 ± 3.620 ms | 0.9976×; 4/10 candidate wins | -2.748 to +1.359 ms |
| CPU | **213.774 ± 1.480 ms** | 214.255 ± 3.497 ms | 0.9978×; 6/10 candidate wins | -2.542 to +1.271 ms |
| Peak RSS | 75.084 ± 0.011 MiB | **75.081 ± 0.010 MiB** | 1.0000×; 2/10 candidate wins | +0.000 to +0.008 MiB |

The candidate has slightly higher wall and CPU means, and both timing
intervals cross zero. The probe therefore failed its primary gate and was
fully reverted without a confirmation, scale run, source commit, or competitor
checkpoint. Raw exact-output checks, load snapshots, and every timing round
are retained under
`bench/vs_tsgo/results/directive-broad-marker-gate.20260901T094320Z/`.

### Checker directive marker indexing (rejected)

The post-HIR-reservation 32,768-family profile showed three whole-source
searches after checking: the unreachable-code pass searched separately for
the true and false `allowUnreachableCode` spellings, and the final diagnostic
cleanup searched for `noImplicitThis`. The rejected probe registered the five
exact accepted spellings in the driver's existing one-pass source-marker
index and reused their recorded first positions. This preserved the previous
substring semantics and removed those three scans from the post-change
profile; it was a general source-size optimization, not a predicate-specific
shortcut.

The fixed baseline binary is SHA-256
`c66959f3321a4649d607dffb1d095cc1146454a4ac400420930f55b962cdbe06`.
The exact final-source candidate is
`65c2f95f8733ad569d00bfa25edb72bcafebc18257fdf77c68eddb55de4b2339`.
The complete ReleaseFast checker and TS driver suites passed, as did all
**95/95** benchmark-harness tests, `zig fmt --check`, and `git diff --check`.
A focused behavioral test preserved `noImplicitThis: false` suppression.
Baseline and candidate both exited zero with byte-identical empty stdout and
stderr on the unchanged official 2,048-family project and the deterministic
32,768-family diagnostic copy.

The first exact-final-source official set was directionally positive but
inconclusive. Before seeing another result, the decision rule was fixed to one
additional independent 30-pair set and an aggregate over all 60 final-binary
pairs, retaining the first set. Every set used three alternating warmup pairs,
reversed process order in every measured pair, and retained every sample.
Paired intervals are baseline-minus-candidate:

| Official 2,048-family A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| First final-source set, 30 pairs | Wall | 227.277 ± 3.927 ms | **226.107 ± 5.174 ms** | 1.0052×; 20/30 wins | -0.348 to +2.503 ms |
| First final-source set, 30 pairs | CPU | 225.707 ± 3.890 ms | **224.550 ± 5.147 ms** | 1.0051×; 20/30 wins | -0.327 to +2.446 ms |
| Second final-source set, 30 pairs | Wall | 231.640 ± 9.081 ms | **227.141 ± 4.851 ms** | 1.0198×; 24/30 wins | **+1.415 to +8.487 ms** |
| Second final-source set, 30 pairs | CPU | 229.561 ± 6.919 ms | **225.522 ± 4.584 ms** | 1.0179×; 25/30 wins | **+1.520 to +7.024 ms** |
| All final-source pairs, 60 pairs | Wall | 229.459 ± 7.277 ms | **226.624 ± 5.000 ms** | **1.0125×; 44/60 wins** | **+1.070 to +4.996 ms** |
| All final-source pairs, 60 pairs | CPU | 227.634 ± 5.895 ms | **225.036 ± 4.857 ms** | **1.0115×; 45/60 wins** | **+1.109 to +4.274 ms** |

Peak RSS was statistically flat across the 60 official pairs: 75.071 ± 0.011
MiB for both rounded means, with a baseline-minus-candidate interval of
-0.003 to +0.004 MiB.

The separately required final-source 32,768-family set did not clear the
precommitted wall-time gate:

| Diagnostic 32,768-family A/B, 10 pairs | Baseline | Candidate | Result | Paired 95% CI |
|---|---:|---:|---:|---:|
| Wall | 5697.627 ± 1502.489 ms | **5584.008 ± 1722.591 ms** | 1.0203×; 7/10 wins | **-416.122 to +760.379 ms** |
| CPU | 5052.219 ± 903.888 ms | **4849.417 ± 907.554 ms** | 1.0418×; 7/10 wins | +0.428 to +550.640 ms |
| Peak RSS | 964.639 ± 48.742 MiB | **956.275 ± 67.481 MiB** | 1.0087×; 4/10 wins | +0.005 to +25.072 MiB |

The retained host snapshots explain the extreme dispersion but do not erase
it. A Zig build was already using one core at the start; by the end, ten
unrelated `zig-js` test processes each occupied roughly 80–91% of a core.
Individual paired wall differences ranged from -1473.438 to +2517.279 ms.
No observation was filtered, replaced, or selectively rerun. Because the
final scale wall interval crosses zero, the probe was rejected and completely
reverted despite the positive official aggregate. Raw profiles, exact-output
checks, preliminary evidence, both final official sets, the 60-pair aggregate,
and the final scale set are retained under
`bench/vs_tsgo/results/directive-marker-index.20260901T090828Z/`.

### Token-count HIR reservation

Commit `ed8bf949b`, tracked in
[#416](https://github.com/home-lang/home/issues/416), reserves parse-time HIR
storage once the lexer has produced the exact token count. HIR appends every
node to five parallel hot columns (`kind`, span, parent, type, and payload) and
stores variable-arity child edges in a sixth array. Previously each array grew
independently and copied its accumulated prefix several times. The accepted
change uses `tokens + 1` as one source-proportional capacity hint for all six
arrays before parsing. It changes capacity only: sentinel lengths, NodeIds,
parent links, payload order, recovery behavior, and diagnostics are unchanged.
Parser recovery can exceed the hint and retains ordinary exact ArrayList
growth.

The fixed accepted baseline binary is SHA-256
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`;
the accepted candidate is
`c66959f3321a4649d607dffb1d095cc1146454a4ac400420930f55b962cdbe06`.
The complete HIR, TS driver, TS parser, and ReleaseFast `ts_checker` suites
pass, as do all **95/95** benchmark-harness tests. A focused HIR invariant test
proves reservation preserves sentinel lengths and the first allocated NodeId.
Both binaries also exited zero with byte-identical empty stdout and stderr on
the unchanged 2,048-family predicate project and deterministic 32,768- and
65,536-family copies generated by changing only the family count.

Every A/B set used three alternating warmup pairs, reversed process order in
every measured pair, retained every sample, and reports untrimmed mean ± sample
standard deviation. The 30-pair official confirmation was independent of the
screen. The diagnostic 32,768-family run changed only generator scale and
removed its validated 48 MB temporary corpus after recording exact outputs and
all timing rounds. Paired intervals are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 219.647 ± 4.992 ms | **216.064 ± 3.003 ms** | **1.0166×; 10/10 wins** | **+2.015 to +5.291 ms** |
| Official 2,048 families, 10-pair screen | CPU | 218.469 ± 4.785 ms | **214.882 ± 2.929 ms** | **1.0167×; 10/10 wins** | **+2.146 to +5.167 ms** |
| Official 2,048 families, 30-pair confirmation | Wall | 222.721 ± 9.704 ms | **218.584 ± 3.863 ms** | **1.0189×; 26/30 wins** | **+1.456 to +7.648 ms** |
| Official 2,048 families, 30-pair confirmation | CPU | 220.865 ± 7.730 ms | **217.313 ± 3.780 ms** | **1.0163×; 27/30 wins** | **+1.420 to +6.333 ms** |
| Diagnostic 32,768 families, 10 pairs | Wall | 3885.596 ± 133.312 ms | **3859.890 ± 113.374 ms** | **1.0067×; 8/10 wins** | **+1.671 to +50.651 ms** |
| Diagnostic 32,768 families, 10 pairs | CPU | 3874.683 ± 123.916 ms | **3852.885 ± 110.856 ms** | **1.0057×; 8/10 wins** | **+0.138 to +44.724 ms** |

On the official workload, reservation increases peak RSS by **0.509 MiB** in
the 30-pair confirmation (74.559 ± 0.516 MiB to 75.068 ± 0.013 MiB; paired
interval +0.337 to +0.681 MiB for candidate-minus-baseline). At 32,768
families the candidate instead lowers mean peak RSS by **3.147 MiB**
(1001.611 ± 2.482 MiB to 998.464 ± 4.146 MiB; baseline-minus-candidate interval
+0.786 to +5.509 MiB), because the single estimate avoids geometric-growth
overcapacity. Substantial unrelated Spotlight, git, FSEvents, and application
activity remains visible in the retained load snapshots. Alternating order and
independent positive decision intervals, rather than filtered samples, support
acceptance.

The independent focused schema-3 checkpoint `20260901T084648Z` verified every
compiler and tool payload before and after 30 rotating-order rounds:

| Focused workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `type_predicates_large` | 1006.1 ± 35.5 ms | 350.3 ± 11.1 ms | **221.7 ± 6.0 ms** | **1.58× faster** |

Home wins all 30 focused wall pairs against both references. The
native-TS-7-minus-Home paired wall interval is **+125.455 to +132.086 ms**;
process CPU also favors Home in all 30 pairs. The subsequent complete
schema-3 checkpoint `20260901T084835Z`, published as the [current
snapshot](#current-snapshot), verifies the same immutable candidate across all
20 workloads: Home has the lowest mean in **20/20**, wins all **600/600** wall
pairs against native TS 7.0.2, and every paired interval is positive. The
narrowest interval lower bound is **+21.109 ms** on `reexport_graph`. Raw A/B
evidence is retained under
`bench/vs_tsgo/results/hir-token-reservation.20260901T133000Z/`; both competitor
checkpoints retain verified metadata and every round file in their timestamped
result directories.

### Default-export merge bucket records

Commit `1a7ac8a7a`, tracked in
[#416](https://github.com/home-lang/home/issues/416), reduces temporary
allocation and copying in `checkDefaultExportMerges`. That pass groups every
top-level merging declaration by its interned name and virtual source section.
Each bucket previously maintained five parallel dynamic arrays for declaration
nodes, owner nodes, export flags, and declaration spaces. Even a unique name
therefore allocated and grew five buffers before the pass discovered that no
merge existed.

Each bucket now appends one record containing the four facts actually consumed
by merge analysis. Grouping keys, insertion order, declaration-space unions,
diagnostic conditions, and diagnostic order are unchanged; the unused owner
entry is gone. The common unique-name bucket performs one allocation instead
of five, while genuine merge buckets retain the same exact records in the same
order. This is a general representation improvement, not a source marker,
workload gate, cache, or benchmark mode.

The fixed accepted baseline binary is SHA-256
`ca0bda46834cc05f9c5f57bac5dd5bdec88af388cf6b7c6fc39fcce9b60604ae`;
the accepted candidate is
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-, 32,768-, and 65,536-family predicate projects. Focused default-export
and TS2395 merge tests pass, as do the complete ReleaseFast `ts_checker` suite
and all **95/95** benchmark-harness tests.

Every A/B set used three alternating warmup pairs, reversed process order in
every measured pair, retained every sample, and reports untrimmed mean ± sample
standard deviation. The 30-pair confirmation was independent of the screen.
Paired intervals are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 241.374 ± 14.475 ms | **235.917 ± 10.657 ms** | **1.0231×; 9/10 wins** | **+0.330 to +10.584 ms** |
| Official 2,048 families, 10-pair screen | CPU | 238.947 ± 13.544 ms | **233.828 ± 10.180 ms** | **1.0219×; 9/10 wins** | **+0.354 to +9.884 ms** |
| Official 2,048 families, 30-pair confirmation | Wall | 240.368 ± 12.673 ms | **233.717 ± 14.413 ms** | **1.0285×; 24/30 wins** | **+3.677 to +9.625 ms** |
| Official 2,048 families, 30-pair confirmation | CPU | 237.972 ± 11.798 ms | **231.652 ± 12.909 ms** | **1.0273×; 25/30 wins** | **+3.520 to +9.121 ms** |
| Diagnostic 32,768 families, 10 pairs | Wall | 3974.070 ± 96.984 ms | 3903.403 ± 138.051 ms | 1.0181×; 9/10 wins | -48.164 to +189.498 ms |
| Diagnostic 32,768 families, 10 pairs | CPU | 3965.214 ± 94.695 ms | **3873.200 ± 82.108 ms** | **1.0238×; 9/10 wins** | **+10.202 to +173.825 ms** |
| Diagnostic 65,536 families, 10 pairs | Wall | 8722.056 ± 513.095 ms | 8392.079 ± 529.550 ms | 1.0393×; 7/10 wins | -113.024 to +772.979 ms |
| Diagnostic 65,536 families, 10 pairs | CPU | 8584.237 ± 389.892 ms | 8320.124 ± 474.210 ms | 1.0317×; 7/10 wins | -61.514 to +589.739 ms |

The independent official confirmation is decisive for both metrics, and the
32,768-family CPU interval independently clears zero. The 32,768 wall result
and both 65,536 metrics retain lower candidate means but are explicitly
inconclusive because their intervals cross zero. They were neither filtered
nor used to strengthen the acceptance claim.

The independent schema-3 checkpoint `20260901T065015Z` version-verified
JavaScript TypeScript 6.0.3 and native TypeScript 7.0.2, hashed every compiler
and tool payload before and after timing, and retained 30 rotating-order rounds
after three warmups:

| Focused workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `type_predicates_large` | 1004.8 ± 26.3 ms | 347.4 ± 9.4 ms | **224.5 ± 10.1 ms** | **1.55× faster** |

Home wins all 30 focused wall pairs against both references. The
native-TS-7-minus-Home paired 95% interval is **+118.439 to +127.422 ms**;
process CPU also favors Home in all 30 pairs. At admission, the subsequent
complete schema-3 checkpoint `20260901T065201Z` verified that accepted binary
across all 20 workloads: Home had the lowest mean in **20/20**, won all
**600/600** paired rounds against native TS 7, and every paired interval was
positive. Raw A/B
evidence is retained under
`bench/vs_tsgo/results/default-export-bucket-records.20260901T074000Z/`; both
competitor checkpoints retain their metadata and every round file in their
timestamped result directories.

### Rejected recovered-parameter identity reuse

The accepted-binary 65,536-family profile put `string_interner.internAt` at
the top of the stack and sampled it directly below
`recoveredSourceParameterAnnotationType`. The source-recovery index scans
simple parameter annotations so malformed legacy HIR can recover an annotation
that lost its parameter ownership. A representation probe reused the existing
HIR `StringId` for well-formed, unqualified, argument-free `type_ref`
annotations instead of hashing and looking up the same source bytes again. It
kept source interning for annotations without that exact HIR identity. The
probe also consulted the completed recovery-name index before walking lexical
parents, because a missing name proves that the fallback cannot apply.

The fixed accepted baseline binary is SHA-256
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`;
the experimental candidate was
`b7b91c25a92f5835b224425e4f16d7370bc532cc34e87c2a7e5fdcdbb8f9a10d`.
Focused recovered-parameter tests, the complete ReleaseFast `ts_checker`
suite, all **95/95** benchmark-harness tests, formatting, and diff checks
passed. Both binaries also exited zero with byte-identical empty stdout and
stderr on the unchanged 2,048-family predicate project and deterministic
32,768- and 65,536-family copies generated by changing only the family count.

Every timing set used three alternating warmup pairs, reversed process order
in every measured pair, retained every sample, and reports untrimmed mean ±
sample standard deviation. The 30-pair official confirmation was independent
of the initial screen. The diagnostic 65,536-family run used the identical
generator and flags with only the family count changed; its 97 MB temporary
corpus was removed after recording the exact outputs and timing rounds. Paired
intervals are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 219.909 ± 2.905 ms | **218.676 ± 2.388 ms** | **1.0056×; 7/10 wins** | **+0.215 to +2.298 ms** |
| Official 2,048 families, 10-pair screen | CPU | 218.790 ± 2.899 ms | **217.510 ± 2.292 ms** | **1.0059×; 7/10 wins** | **+0.371 to +2.251 ms** |
| Official 2,048 families, 30-pair confirmation | Wall | 221.980 ± 3.399 ms | 221.056 ± 3.515 ms | 1.0042×; 18/30 wins | -0.657 to +2.625 ms |
| Official 2,048 families, 30-pair confirmation | CPU | 220.665 ± 2.747 ms | 219.834 ± 3.315 ms | 1.0038×; 17/30 wins | -0.573 to +2.267 ms |
| Diagnostic 65,536 families, 10 pairs | Wall | 7852.527 ± 49.921 ms | 7841.785 ± 39.109 ms | 1.0014×; 8/10 wins | -7.949 to +27.006 ms |
| Diagnostic 65,536 families, 10 pairs | CPU | 7842.963 ± 49.594 ms | 7829.558 ± 37.970 ms | 1.0017×; 8/10 wins | -5.089 to +29.924 ms |

The screen separated in the candidate's favor, but neither the predeclared
official confirmation nor the larger scaling run established pair direction:
all four decision intervals crossed zero. Load snapshots also retained
substantial unrelated Spotlight activity, plus transient MySQL or Typesense
work in individual sets; no sample was filtered or rerun selectively. The
probe therefore failed the acceptance gate despite lower candidate means in
all six rows. The source change was fully reverted and the accepted binary
restored. Frozen binaries, all exact outputs, every timing round, and load
snapshots are retained under
`bench/vs_tsgo/results/recovered-parameter-identity-reuse.20260901T123000Z/`.

### Rejected namespace declaration-pass gate

The accepted-binary profile attributed 223 top-of-stack samples to
`checkDeclarationSpaceDiagnosticsImpl`. Four child passes independently scan
the same statement list but can only act on namespace, module, or global
declarations. An exact necessary-condition probe used the existing source
marker fact to skip all four when attached source contained none of those
spellings. False-positive source text still ran the original passes, while
source-less/HIR-only integrations always retained the original path. Focused
tests covered reopened namespace interface merging, sibling namespace class
and function diagnostics, ambient-module collisions, and an explicit HIR-only
fallback regression. The complete ReleaseFast `ts_checker` suite also passed.

The fixed accepted baseline binary is SHA-256
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`;
the experimental candidate was
`5b5f4e3f32a962786332699b97da30ff50312bbefbe7f8a138fd657861f78709`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-family predicate project and deterministic 32,768- and 65,536-family
copies generated by changing only the family count.

The first 10-pair set used three alternating warmup pairs, reversed order in
every measured pair, and retained every sample. Its snapshots showed an
unrelated Bun job consuming 116% CPU at the start but absent at the end, while
Time Machine began by the end. The whole set was therefore retained but
excluded before deciding; it reported wall 222.545 ± 4.547 ms versus
223.395 ± 3.662 ms (1.0038× slower, 5/10 wins, paired CI -4.897 to
+3.197 ms) and CPU 221.348 ± 4.361 ms versus 222.156 ± 3.624 ms
(1.0037× slower, 5/10 wins, paired CI -4.602 to +2.984 ms).

One predeclared rerun used the same frozen binaries and protocol after those
loads cleared. Its before/after snapshots contained only stable system and
application activity; no sample was filtered or restarted. Paired intervals
are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair rerun | Wall | 218.447 ± 2.484 ms | 218.034 ± 2.028 ms | 1.0019×; 6/10 wins | -1.380 to +2.207 ms |
| Official 2,048 families, 10-pair rerun | CPU | 217.430 ± 2.401 ms | 216.850 ± 1.979 ms | 1.0027×; 7/10 wins | -1.109 to +2.269 ms |

Neither clean-rerun metric established pair direction and both intervals
crossed zero. The initial gate therefore failed; no confirmation, scale
timing, or compiler checkpoint was admitted. The source probe and regression
were fully reverted and the accepted binary restored. Frozen binaries, exact
outputs, both complete screens, and load snapshots are retained under
`bench/vs_tsgo/results/namespace-declaration-pass-gate.20260901T111500Z/`.

### Rejected local-boundary NodeId keys

The accepted-binary profile attributed 73 top-of-stack samples to
`findLocalValueDeclBeforeExpression` and another 28 to growth of its statement
boundary map. That map keyed each boundary by both its globally unique HIR
`NodeId` and virtual-section start. An exact representation probe keyed the
boundary ordinal by `NodeId` alone; declaration keys remained partitioned by
virtual section, and every ordinal comparison and allocation-failure fallback
was unchanged. The focused index suite compares indexed and slow-scanner
results for every node and name across multiple virtual files, export
wrappers, nested scopes, and declarations, and it passed alongside the
complete ReleaseFast `ts_checker` suite.

The fixed accepted baseline binary is SHA-256
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`;
the experimental candidate was
`095293d6e08b0c264027bc86cd4577365d0db57f44f2398993bb8ceb07782494`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-family predicate project and deterministic 32,768- and 65,536-family
copies generated by changing only the family count.

The official screen used three alternating warmup pairs, reversed process
order in every measured pair, retained every sample, and reports untrimmed
mean ± sample standard deviation. A separate one-core `zig-js` parent/candidate
benchmark remained present in both load snapshots. Paired intervals are
baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 228.922 ± 3.841 ms | 228.610 ± 2.939 ms | 1.0014×; 6/10 wins | -1.605 to +2.229 ms |
| Official 2,048 families, 10-pair screen | CPU | 227.242 ± 3.518 ms | 227.108 ± 2.872 ms | 1.0006×; 6/10 wins | -1.398 to +1.665 ms |

The candidate's resident-set mean was 0.3% lower, but only five of ten memory
pairs favored it and neither timing metric established pair direction. The
initial gate therefore failed; no confirmation, scale timing, or compiler
checkpoint was admitted. The source probe was fully reverted and the accepted
binary restored. Frozen binaries, exact outputs, every screen round, and load
snapshots are retained under
`bench/vs_tsgo/results/local-boundary-node-keys.20260901T102500Z/`.

### Rejected duplicate-class second-pass gate

The accepted-binary profile sampled the declaration map in
`checkInterfacesMergedWithDuplicateClasses`. After building the complete class
map, that pass rescanned every statement for interfaces even when no class key
had reached the duplicate threshold, a state in which the second scan cannot
emit a diagnostic. An exact probe tracked whether any class group became a
duplicate and returned only when none did. The class scan, map contents,
duplicate counts, first-declaration anchors, and reporting path were unchanged.
A focused regression covered three same-name classes interleaved with two
merged interfaces, ensuring the reporting path still runs and produces all
five TS2300 diagnostics.

The fixed accepted baseline binary is SHA-256
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`;
the experimental candidate was
`2d62489c7daf2d5d1fa44d5aff3c40f2e75b09d8fbf9c2d7bf8c7fc331cfbf40`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-family predicate project and deterministic 32,768- and 65,536-family
copies generated by changing only the family count. The focused regression
and complete ReleaseFast `ts_checker` suite passed.

The official screen used three alternating warmup pairs, reversed process
order in every measured pair, retained every sample, and reports untrimmed
mean ± sample standard deviation. A separate one-core `zig-js` benchmark was
present in both load snapshots; its worker changed while the load class
remained present. Paired intervals are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 225.297 ± 3.702 ms | 223.708 ± 2.394 ms | 1.0071×; 5/10 wins | -0.394 to +3.571 ms |
| Official 2,048 families, 10-pair screen | CPU | 223.789 ± 3.469 ms | 222.307 ± 2.316 ms | 1.0067×; 7/10 wins | -0.355 to +3.319 ms |

Neither metric established pair direction and both intervals crossed zero.
The initial gate therefore failed; no confirmation, scale timing, or compiler
checkpoint was admitted. The source probe and regression were fully reverted
and the accepted binary restored. Frozen binaries, exact outputs, every screen
round, and load snapshots are retained under
`bench/vs_tsgo/results/duplicate-class-second-pass-gate.20260901T094500Z/`.

### Rejected duplicate-class threshold flag

The accepted-binary profile attributed repeated samples to the declaration
map used by `checkInterfacesMergedWithDuplicateClasses`. Its `ClassGroup`
stored a full `usize` count even though downstream logic only distinguishes
one class from two-or-more classes. An exact probe replaced that count with a
`has_duplicate` flag while retaining the first declaration anchor, key,
iteration order, and diagnostic condition. A focused regression covered three
same-name classes interleaved with two merged interfaces, ensuring that every
declaration still receives TS2300 exactly once.

The fixed accepted baseline binary is SHA-256
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`;
the experimental candidate was
`6efc4fd1744b01a7efb49fe59ccd9d127b53fb1e699332918260a0d89535504e`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-family predicate project and deterministic 32,768- and 65,536-family
copies generated by changing only the family count. The focused regression
and complete ReleaseFast `ts_checker` suite passed.

The first 10-pair set used three alternating warmup pairs, reversed order in
every measured pair, and retained every sample. Its load snapshots showed an
unrelated Bun job consuming 34% CPU at the start but absent at the end. That
whole set was therefore retained but excluded before making the decision; it
reported wall 225.065 ± 6.758 ms versus 224.671 ± 7.567 ms (1.0018×, 7/10
wins, paired CI -1.872 to +2.661 ms) and CPU 223.756 ± 6.406 ms versus
223.151 ± 7.142 ms (1.0027×, 7/10 wins, paired CI -1.592 to +2.802 ms).

One predeclared rerun used the same frozen binaries and protocol. A separate
test262 shard and Spotlight each held approximately one core throughout; the
test262 worker PID rotated, but its load class remained present in both
snapshots. No sample was filtered or restarted. Paired intervals are
baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair rerun | Wall | **226.580 ± 2.854 ms** | 228.710 ± 4.979 ms | 1.0094× slower; 4/10 wins | -4.636 to +0.375 ms |
| Official 2,048 families, 10-pair rerun | CPU | **225.118 ± 2.760 ms** | 227.103 ± 4.789 ms | 1.0088× slower; 4/10 wins | -4.247 to +0.278 ms |

The designated rerun was directionally slower and neither paired interval
established a candidate benefit. The initial gate therefore failed; no scale
timing, confirmation, or compiler checkpoint was admitted. The source probe
and regression were fully reverted and the accepted binary restored. Frozen
binaries, exact outputs, both complete screens, and load snapshots are
retained under
`bench/vs_tsgo/results/duplicate-class-flag.20260901T091500Z/`.

### Rejected type-alias merge inline-first targets

The post-bucket profile under
`predicate-post-bucket-profile.20260901T070000Z` attributed 223 top-of-stack
samples to `checkDeclarationSpaceDiagnosticsImpl`. One child pass,
`checkTypeAliasDeclarationMergeDiagnostics`, stored a dynamic list for every
class/interface name even when the group contained only one declaration. An
exact probe kept the first target inline in the map value and allocated an
overflow list only for genuine multi-target groups. Target order and the
alias-to-every-target diagnostic loop were unchanged; a focused regression
covered an alias conflicting with both a class and its merged interface.

The fixed accepted baseline binary is SHA-256
`9e86ee995ca30484ae41d0f0adafea23a386d1ad57fd932b4941909c20d4711d`;
the experimental candidate was
`d0e1896e83807ca257b7bd45fce2d1e72a02c7f1c935c8daac6871db15b185f6`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-, 32,768-, and 65,536-family predicate projects. The focused type-alias
checker suite passed, including the multi-target overflow regression.

The official screen retained all ten reversed-order pairs after three
alternating warmup pairs. Two unrelated Zig test shards in another repository
held a stable two-core load throughout; no sample was filtered or restarted.
Paired intervals are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 232.604 ± 14.432 ms | 230.552 ± 5.974 ms | 1.0089×; 6/10 wins | -5.243 to +9.348 ms |
| Official 2,048 families, 10-pair screen | CPU | 229.749 ± 11.273 ms | 228.636 ± 5.582 ms | 1.0049×; 5/10 wins | -4.146 to +6.371 ms |

The external load may widen variance, but neither metric established pair
direction and both intervals crossed zero. The initial gate therefore failed;
no confirmation, scale timing, or competitor checkpoint was run. The source
probe was fully reverted and the accepted binary restored. Raw binaries,
exact outputs, and every screen round are retained under
`bench/vs_tsgo/results/type-alias-merge-inline-first.20260901T083000Z/`.

### Exact diagnostic-reconciliation marker gate

Commit `587c64343`, tracked in
[#416](https://github.com/home-lang/home/issues/416), avoids an unnecessary
post-check source scan on ordinary files. Sampling the unchanged 65,536-family
`type_predicates_large` project identified
`applyCompilerCorpusExactDiagnosticReconciliations` as the dominant sampled
checker leaf. That compatibility pass searched every source separately for a
small set of exact upstream-corpus constructs even though none occur in the
valid predicate workload.

The checker now includes one necessary sentinel for every reconciliation
branch in the source marker index already built by `prepareSource`. If none of
those exact sentinels is present, the reconciliation pass returns immediately;
if any is present, every original exact condition and diagnostic action still
runs. The uncached checker path retains exact `indexOf` fallback behavior. This
is a general necessary-condition gate over real source text, not a workload
name, result cache, diagnostic shortcut, or benchmark-only mode.

The fixed baseline binary is SHA-256
`5748ad8edbbb55ad43bfa84a11d3f87c10ae1994e9de01b138640d970977e5f3`;
the accepted candidate is
`ca0bda46834cc05f9c5f57bac5dd5bdec88af388cf6b7c6fc39fcce9b60604ae`.
Both exit zero with byte-identical empty stdout and stderr on the unchanged
official 2,048-family project and deterministic 32,768- and 65,536-family
copies generated with only the family count changed. A focused test covers
every sentinel through both indexed and fallback lookup paths. The complete
ReleaseFast `ts_checker` suite and all 95 benchmark-harness tests pass.

Every A/B set used three alternating warmup pairs, reversed process order in
each measured round, retained every sample, and reports untrimmed mean ± sample
standard deviation. Paired intervals are baseline-minus-candidate; intervals
wholly above zero favor the candidate.

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 249.171 ± 2.809 ms | **243.385 ± 2.695 ms** | **1.0238×; 9/10 wins** | **+2.831 to +8.742 ms** |
| Official 2,048 families, 10-pair screen | CPU | 246.565 ± 2.789 ms | **240.868 ± 2.462 ms** | **1.0237×; 9/10 wins** | **+2.846 to +8.548 ms** |
| Official 2,048 families, 30-pair confirmation | Wall | 248.825 ± 3.471 ms | **242.644 ± 8.619 ms** | **1.0255×; 28/30 wins** | **+2.540 to +9.822 ms** |
| Official 2,048 families, 30-pair confirmation | CPU | 246.300 ± 3.345 ms | **239.937 ± 7.287 ms** | **1.0265×; 29/30 wins** | **+3.228 to +9.499 ms** |
| Diagnostic 32,768 families, 10 pairs | Wall | 4370.414 ± 50.111 ms | **4271.202 ± 42.435 ms** | **1.0232×; 10/10 wins** | **+69.986 to +128.437 ms** |
| Diagnostic 32,768 families, 10 pairs | CPU | 4347.483 ± 47.148 ms | **4247.370 ± 36.548 ms** | **1.0236×; 10/10 wins** | **+75.027 to +125.199 ms** |
| Diagnostic 65,536 families, 10 pairs | Wall | 9299.204 ± 186.830 ms | 9173.403 ± 254.585 ms | 1.0137×; 8/10 wins | -44.569 to +296.173 ms |
| Diagnostic 65,536 families, 10 pairs | CPU | 9194.124 ± 162.523 ms | 9078.005 ± 220.901 ms | 1.0128×; 8/10 wins | -48.866 to +281.103 ms |

The official screen and independent 30-pair confirmation are decisive, as is
the 32,768-family scale check. The retained 65,536-family set has lower
candidate means but is explicitly inconclusive because both paired intervals
cross zero; it was neither filtered nor used as the acceptance gate.

The schema-3 competitor checkpoint `20260901T051415Z` independently admitted
the official workload against JavaScript TypeScript 6.0.3 and native
TypeScript 7.0.2 (`tsgo`), verified compiler and tool payloads before and after
timing, and ran 30 rotating-order rounds after three warmups:

| Focused workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `type_predicates_large` | 1178.4 ± 145.4 ms | 401.6 ± 32.8 ms | **267.2 ± 55.9 ms** | **1.50× faster** |

Home had the lower wall time in 29/30 pairs against native TS 7 and all 30
pairs against TS 6. Its native-TS-7-minus-Home paired wall interval is
**+120.576 to +148.318 ms**; process CPU favored Home in all 30 pairs against
both references. Raw profile, exact-output, and A/B evidence is retained under
`bench/vs_tsgo/results/predicate-current-profile.20260901T045324Z/` and
`bench/vs_tsgo/results/exact-diagnostic-marker-gate.20260901T045636Z/`;
the pinned-competitor rounds and verified provenance are under
`bench/vs_tsgo/results/20260901T051415Z/`.

### Rejected parser JSDoc-presence reuse

The post-marker-gate 65,536-family profile under
`predicate-post-gate-profile.20260901T052300Z` showed 255 top-of-stack samples
in `reportJSDocTypeArgumentSyntaxDiagnostics`. The logical probe supplied the
parser with the exact `/**` presence fact already computed by the shared source
marker index. Indexed callers could skip the parser's standalone byte scan only
when absence was proven, while direct parser callers retained the existing
fallback. A positive-path driver regression preserved real JSDoc diagnostics.

The fixed accepted baseline binary is SHA-256
`ca0bda46834cc05f9c5f57bac5dd5bdec88af388cf6b7c6fc39fcce9b60604ae`;
the experimental candidate was
`46bb697b636891de8b8d9e3472260525c85d267d4880cebbed8183593446711a`.
Both exit zero with byte-identical empty stdout and stderr on unchanged 2,048-,
32,768-, and 65,536-family predicate projects. The complete parser and driver
test suites passed. These correctness results do not substitute for a measured
performance admission.

Every set below retained every sample after three alternating warmup pairs and
reversed process order in each measured pair. Paired intervals are
baseline-minus-candidate. No interval clears zero, so none supports acceptance:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 256.561 ± 9.732 ms | 252.491 ± 10.873 ms | 1.0161×; 9/10 wins | -2.739 to +10.877 ms |
| Official 2,048 families, 10-pair screen | CPU | 252.042 ± 8.962 ms | 248.436 ± 9.805 ms | 1.0145×; 8/10 wins | -2.884 to +10.096 ms |
| Official 2,048 families, 30-pair confirmation | Wall | 254.126 ± 6.418 ms | 252.085 ± 8.404 ms | 1.0081×; 21/30 wins | -1.091 to +5.173 ms |
| Official 2,048 families, 30-pair confirmation | CPU | 248.771 ± 4.054 ms | 246.934 ± 5.092 ms | 1.0074×; 20/30 wins | -0.401 to +4.076 ms |
| First 32,768-family set, 10 pairs | Wall | 4593.952 ± 222.426 ms | 4514.325 ± 254.702 ms | 1.0176×; 6/10 wins | -119.839 to +279.092 ms |
| First 32,768-family set, 10 pairs | CPU | 4487.025 ± 191.128 ms | 4424.545 ± 235.388 ms | 1.0141×; 5/10 wins | -113.987 to +238.947 ms |
| Independent 32,768-family set, 10 pairs | Wall | 4096.643 ± 154.747 ms | 4421.331 ± 961.984 ms | 0.9266×; 5/10 wins | -1034.897 to +385.522 ms |
| Independent 32,768-family set, 10 pairs | CPU | 4063.062 ± 132.979 ms | 4257.522 ± 600.774 ms | 0.9543×; 5/10 wins | -645.169 to +256.249 ms |

The first scale set overlapped four unrelated CPU-saturating test shards. After
those cleared, new test and service startup overlapped rounds 7–8 of the
independent set; the two candidate wall samples were 4999.780 and 7011.918 ms.
Those outliers remain in the table and raw files. The result is treated as an
environmental admission failure rather than filtered, pooled, or reframed as a
speed claim. Because the official confirmation also remained inconclusive, the
source probe was reverted and the accepted baseline binary restored. Raw
evidence is retained under
`bench/vs_tsgo/results/jsdoc-parser-presence-gate.20260901T053000Z/`.

### Rejected parser virtual-section fact reuse

The driver already records exact `@filename:` and `@Filename:` presence in the
shared source-marker index. A logical probe added an explicit parser
constructor for that fact so driver-prepared sources could avoid the two
standalone `indexOf` calls in `Parser.init`; direct parser callers retained the
original discovery path. A mixed-file regression exercised the explicit-fact
constructor with uppercase `@Filename:` sections.

The fixed accepted baseline binary is SHA-256
`ca0bda46834cc05f9c5f57bac5dd5bdec88af388cf6b7c6fc39fcce9b60604ae`;
the experimental candidate was
`3e902387bd0adccbb4642407467f90e7ce3f2de29faccc8d602fa1f24c54d378`.
Both produced byte-identical output at the unchanged 2,048-, 32,768-, and
65,536-family predicate scales. They also returned the same nonzero status and
byte-identical 348-byte diagnostic output for a mixed `.d.ts`/`.js` virtual
fixture. The complete parser and driver suites passed.

Each retained set used three alternating warmup pairs and reversed process
order in every measured pair. Paired intervals are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 242.047 ± 5.350 ms | 240.399 ± 4.425 ms | 1.0069×; 8/10 wins | -2.942 to +6.237 ms |
| Official 2,048 families, 10-pair screen | CPU | 239.772 ± 5.028 ms | 238.133 ± 3.994 ms | 1.0069×; 8/10 wins | -2.714 to +5.992 ms |
| Diagnostic 32,768 families, 10 pairs | Wall | 4069.149 ± 128.847 ms | 4062.120 ± 115.320 ms | 1.0017×; 4/10 wins | -44.382 to +58.439 ms |
| Diagnostic 32,768 families, 10 pairs | CPU | 4045.291 ± 122.162 ms | 4034.395 ± 105.810 ms | 1.0027×; 4/10 wins | -43.525 to +65.318 ms |

The unchanged larger project did not amplify the apparent official-screen
gain: both means were near ties, only four candidate wins occurred, and both
paired intervals crossed zero. The source probe was therefore rejected and
fully reverted without a confirmation or competitor checkpoint. Every sample
is retained under
`bench/vs_tsgo/results/parser-virtual-section-fact.20260901T055116Z/`.

### Rejected reconciliation-sentinel root-set pruning

The accepted exact diagnostic-reconciliation gate added ten rare sentinels to
the shared Aho–Corasick source-marker index. Six introduced first bytes not
used by the original 39 markers, which expanded the root-state byte set used
by `indexOfAnyPos`. This exact probe replaced only those six sentinels with
necessary suffixes whose first bytes already occurred in the original set.
The complete branch-specific conditions in
`applyCompilerCorpusExactDiagnosticReconciliations` remained unchanged, so a
suffix could only trigger the existing exact reconciliation checks; it could
not suppress or create a diagnostic by itself.

The fixed accepted baseline binary is SHA-256
`ca0bda46834cc05f9c5f57bac5dd5bdec88af388cf6b7c6fc39fcce9b60604ae`;
the experimental candidate was
`cafc7e811c5dc8e1c1c1ef729dd22ca1c2e037edefe6e7700156cb2067104748`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-, 32,768-, and 65,536-family predicate projects. Focused source-marker
and exact reconciliation-gate tests passed, including indexed and fallback
paths plus coverage of every sentinel.

Every retained set used three alternating warmup pairs, reversed process order
in every measured pair, retained every finite sample, and reports untrimmed
mean ± sample standard deviation. The 30-pair confirmation was independent of
the initial screen. Paired intervals are baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 229.344 ± 2.895 ms | **226.531 ± 1.847 ms** | **1.0124×; 9/10 wins** | **+0.383 to +5.243 ms** |
| Official 2,048 families, 10-pair screen | CPU | 227.708 ± 2.940 ms | **224.807 ± 2.114 ms** | **1.0129×; 9/10 wins** | **+0.406 to +5.396 ms** |
| Official 2,048 families, 30-pair confirmation | Wall | 227.299 ± 2.680 ms | 226.574 ± 1.759 ms | 1.0032×; 18/30 wins | -0.338 to +1.788 ms |
| Official 2,048 families, 30-pair confirmation | CPU | 225.448 ± 2.758 ms | 224.687 ± 1.783 ms | 1.0034×; 16/30 wins | -0.316 to +1.838 ms |
| Diagnostic 32,768 families, 10 pairs | Wall | **3911.739 ± 25.827 ms** | 3918.677 ± 15.862 ms | 0.9982×; 5/10 wins | -31.177 to +17.302 ms |
| Diagnostic 32,768 families, 10 pairs | CPU | **3896.615 ± 25.726 ms** | 3904.611 ± 15.054 ms | 0.9980×; 5/10 wins | -30.283 to +14.292 ms |

The promising initial screen did not reproduce decisively: the independent
confirmation shrank to about 0.3%, both paired intervals crossed zero, and
pair direction was nearly even. The unchanged 32,768-family scale then had
higher candidate means and only five wins for both metrics. The optimization
was therefore rejected and fully reverted without a competitor checkpoint.
Raw binaries, exact outputs, and every A/B round are retained under
`bench/vs_tsgo/results/reconciliation-root-set.20260901T060254Z/`.

### Rejected union flatten-buffer elision

The post-gate profile retained allocation and copying inside
`Interner.internUnion`. The existing canonicalizer always expands its inputs
into a temporary list before making the separate sortable copy, even when no
input is itself a union. An exact probe kept the caller's immutable slice in
that common case and allocated the expansion list only after finding a nested
union. Nested-union flattening, sorting, deduplication, flag folding, and
interner publication remained unchanged.

The fixed accepted baseline binary is SHA-256
`ca0bda46834cc05f9c5f57bac5dd5bdec88af388cf6b7c6fc39fcce9b60604ae`;
the experimental candidate was
`7a509d9a7537b1d5d95b9d37ca110d5702d6d4a643161fd208fcdbcb370cef8e`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-, 32,768-, and 65,536-family predicate projects. The focused ReleaseFast
union-interner tests passed, including sort/dedup canonicalization, flag
folding, and single and multiple nested unions.

The official screen used three alternating warmup pairs, reversed process
order in every measured pair, retained every sample, and reports untrimmed
mean ± sample standard deviation. Paired intervals are
baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 244.818 ± 18.098 ms | 243.463 ± 12.739 ms | 1.0056×; 6/10 wins | -9.806 to +12.516 ms |
| Official 2,048 families, 10-pair screen | CPU | 241.483 ± 14.992 ms | 240.638 ± 11.692 ms | 1.0035×; 6/10 wins | -8.621 to +10.312 ms |

Neither metric cleared zero or established convincing pair direction. The
initial admission gate therefore failed; no scale timing, confirmation, or
competitor checkpoint was run. The source probe was fully reverted and the
accepted binary restored. Raw binaries, exact outputs, and every screen round
are retained under
`bench/vs_tsgo/results/union-flatten-buffer.20260901T063000Z/`.

### Rejected prepared parser source-fact bundle

The post-gate profile attributed separate scan costs to the parser's JSDoc
diagnostic pre-pass and its two virtual-section presence searches. The driver
already computes exact `/**`, `@filename:`, and `@Filename:` presence in the
shared source-marker index. A combined API probe supplied both facts to
driver-created parsers, skipped the JSDoc pre-pass only when absence was
proven, and retained the original discovery scans for every direct parser
caller. This deliberately tested the coherent bundle after the individual
JSDoc and virtual-section probes were inconclusive.

The fixed accepted baseline binary is SHA-256
`ca0bda46834cc05f9c5f57bac5dd5bdec88af388cf6b7c6fc39fcce9b60604ae`;
the experimental candidate was
`7f71fe50dd77096c5be83bc968f0162ab1d09ecaedf1ad29e22c46ec39ecf742`.
Both exited zero with byte-identical empty stdout and stderr on the unchanged
2,048-, 32,768-, and 65,536-family predicate projects. The complete parser and
driver test suites passed, including direct-parser fallback, prepared-source
JSDoc diagnostics, and virtual-section behavior.

The official screen used three alternating warmup pairs, reversed process
order in every measured pair, retained every sample, and reports untrimmed
mean ± sample standard deviation. Paired intervals are
baseline-minus-candidate:

| Predicate A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 2,048 families, 10-pair screen | Wall | 259.053 ± 20.896 ms | 258.442 ± 26.555 ms | 1.0024×; 5/10 wins | -15.021 to +16.244 ms |
| Official 2,048 families, 10-pair screen | CPU | 252.151 ± 15.066 ms | 250.722 ± 16.447 ms | 1.0057×; 5/10 wins | -8.944 to +11.802 ms |

Removing all three redundant scans together still produced nearly even pair
direction and no interval support. The initial admission gate therefore
failed; no scale timing, confirmation, or competitor checkpoint was run. The
source probe was fully reverted and the accepted binary restored. Raw
binaries, exact outputs, and every screen round are retained under
`bench/vs_tsgo/results/parser-prepared-source-facts.20260901T070000Z/`.

### JSDoc import-type scan pruning

Commit `532373ee1`, tracked in
[#416](https://github.com/home-lang/home/issues/416), removes a quadratic path
from checked-JavaScript files with many ordinary JSDoc blocks. The
`checkJSDocImportTypeModuleTargets` pass previously parsed every block and then
called `jsDocCommentAnchor` before determining whether the block contained an
`import(...)` or `typeof import(...)` type. That anchor lookup scans the
top-level statements, so a file with many comments and statements but no
import types paid a comments-by-statements cost.

The checker now reuses the exact `import` source marker already built during
source preparation. A source without that substring cannot contain either
import-type spelling, so the pass returns without parsing comments. In a mixed
source that does contain `import`, the checker resolves and reuses an anchor
only after encountering a relevant tag. The tag parser, type lowering,
diagnostic order, and resolution behavior at every relevant tag are unchanged;
no result cache or benchmark-only gate was added.

The locally rebuilt baseline binary is SHA-256
`f8a583689b452b8205ab4ebe977fcdafde85e7f29660bd1661e4a2e9b68277b4`;
the accepted candidate is
`5748ad8edbbb55ad43bfa84a11d3f87c10ae1994e9de01b138640d970977e5f3`.
Both exit zero with byte-identical empty stdout and stderr on the unchanged
official 128-family `checkjs_jsdoc` project and on a deterministic
4,096-family project produced by the same generator with only its family count
changed. Focused `ts_checker` tests matching `JSDoc import` pass, including
cross-module type resolution, script-versus-CommonJS behavior, import tags,
export-equals aliases, and invalid import forms. `zig fmt --check` also passes.

Each A/B set used three alternating warmup pairs, reversed process order in
every measured round, retained every sample, and reports untrimmed mean ±
sample standard deviation. The paired interval is baseline-minus-candidate,
so an interval wholly above zero favors the candidate.

| CheckJS/JSDoc A/B | Metric | Baseline | Candidate | Result | Paired 95% CI |
|---|---|---:|---:|---:|---:|
| Official 128 families, 10-pair screen | Wall | 34.465 ± 0.598 ms | **33.918 ± 0.649 ms** | **1.0161×; 8/10 wins** | **+0.147 to +0.946 ms** |
| Official 128 families, 10-pair screen | CPU | 33.394 ± 0.507 ms | **32.901 ± 0.565 ms** | **1.0150×; 8/10 wins** | **+0.255 to +0.731 ms** |
| Official 128 families, first 30-pair confirmation | Wall | 36.928 ± 12.098 ms | 36.574 ± 14.660 ms | 1.0097×; 23/30 wins | -0.660 to +1.368 ms |
| Official 128 families, first 30-pair confirmation | CPU | 34.785 ± 6.213 ms | 34.809 ± 10.612 ms | 0.9993×; 24/30 wins | -1.694 to +1.645 ms |
| Official 128 families, independent 30-pair confirmation | Wall | 35.297 ± 1.198 ms | **34.793 ± 1.071 ms** | **1.0145×; 20/30 wins** | **+0.035 to +0.971 ms** |
| Official 128 families, independent 30-pair confirmation | CPU | 34.235 ± 1.072 ms | **33.702 ± 0.894 ms** | **1.0158×; 19/30 wins** | **+0.151 to +0.916 ms** |
| Diagnostic 4,096 families, 10 pairs | Wall | 6454.022 ± 78.338 ms | **5312.256 ± 67.011 ms** | **1.2149×; 10/10 wins** | **+1086.273 to +1197.257 ms** |
| Diagnostic 4,096 families, 10 pairs | CPU | 6412.810 ± 62.141 ms | **5281.181 ± 55.399 ms** | **1.2143×; 10/10 wins** | **+1084.489 to +1178.770 ms** |

The first confirmation began during transient shared-host activity and retained
all 30 noisy pairs; it is shown separately and was neither filtered nor pooled.
Because its 12–15 ms standard deviations were far above the screen, a second
independent 30-pair confirmation was run and also retained in full. Its wall
and CPU intervals both clear zero. The unchanged larger diagnostic then
confirmed the expected scaling improvement with 10/10 wins.

The schema-3 competitor checkpoint `20260901T044935Z` independently validated
the official workload, compiler versions, rejection controls, and executable
hashes before and after 30 rotating-order rounds following three warmups:

| Focused workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `checkjs_jsdoc` | 241.3 ± 59.1 ms | 64.7 ± 19.5 ms | **39.8 ± 16.9 ms** | **1.63× faster** |

Home had the lower wall time in 29/30 pairs against native TS 7 and all 30
pairs against TS 6; its native-TS-7-minus-Home paired wall interval is
**+21.947 to +27.861 ms**. Process CPU favored Home in 30/30 pairs against
both references. Raw A/B evidence is retained under
`bench/vs_tsgo/results/checkjs-import-type-gate.20260901T043158Z/`; pinned
competitor rounds and verified provenance are under
`bench/vs_tsgo/results/20260901T044935Z/`.

### Program import-resolution reuse

Commit `49641900e`, tracked in
[#416](https://github.com/home-lang/home/issues/416), removes repeated module
resolution from cross-file program-export matching. A single import can be
compared with many candidate CommonJS owners, exported classes, values, types,
or augmentations. Previously every comparison called the external resolver
again and, after a non-match, allocated another `std.fs.path.resolve` result.

The checker now caches the immutable resolution for each exact
`(import node, specifier)` pair. The entry retains both the external-resolver
answer and the existing filesystem fallback, normalized with the same
extension stripping already used by `programModulePathMatches`. It does not
cache a target-specific true/false answer: every candidate owner still goes
through the original exact normalized-path comparison. The cache is cleared
when the source, external resolver, or importer path changes and is released
with the checker.

The fixed accepted baseline binary has SHA-256
`0d2aed7253152acb66965e5148d09c5a50bf7512e9062faecee0daa70caa3f60`;
the candidate is
`ec99b3fcca63f39d97f147bbe2ad5139bf5e53a22f885e25bd1f6eb971386789`.
Both exit 0 with byte-identical empty stdout and stderr on the unchanged
2,048-owner, 2,050-source checked-JavaScript project. That project is the same
deterministic `commonjs_graph` generator scaled only in family count: every
owner exports two concrete class instances and the root consumes their nested
fields through real `require` edges.

Each A/B scale used three alternating warmup pairs, reversed process order in
every measured round, retained every sample, and reports untrimmed mean ±
sample standard deviation. The paired interval is baseline-minus-candidate,
so an interval wholly above zero favors the candidate.

| Scale and gate | Baseline | Candidate | Result | Paired 95% CI |
|---|---:|---:|---:|---:|
| Standard 128 owners, wall, 30 pairs | 36.5 ± 3.1 ms | **30.1 ± 2.0 ms** | **1.212×; 30/30 wins** | **+5.3 to +7.5 ms** |
| Standard 128 owners, CPU, 30 pairs | 51.6 ± 2.9 ms | **44.9 ± 2.9 ms** | **1.149×; 30/30 wins** | **+5.5 to +7.8 ms** |
| Scaled 2,048 owners, wall screen, 10 pairs | 3050.4 ± 111.2 ms | **1433.7 ± 74.6 ms** | **2.128×; 10/10 wins** | **+1516.3 to +1717.2 ms** |
| Scaled 2,048 owners, CPU screen, 10 pairs | 3215.3 ± 99.2 ms | **1609.4 ± 40.6 ms** | **1.998×; 10/10 wins** | **+1540.6 to +1671.2 ms** |
| Scaled 2,048 owners, wall confirmation, 20 pairs | 3471.2 ± 261.2 ms | **1565.2 ± 183.4 ms** | **2.218×; 20/20 wins** | **+1810.0 to +2001.9 ms** |
| Scaled 2,048 owners, CPU confirmation, 20 pairs | 3489.9 ± 166.4 ms | **1705.6 ± 140.4 ms** | **2.046×; 20/20 wins** | **+1728.7 to +1840.0 ms** |

The standard schema-3 competitor checkpoint `20260901T012536Z` independently
validated the unmodified 128-owner workload, verified compiler/tool payloads
before and after timing, and used 30 interleaved rounds after three warmups:

| Focused workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `commonjs_graph` | 263.0 ± 48.8 ms | 83.9 ± 27.9 ms | **42.9 ± 10.5 ms** | **1.95× faster** |

Home won 30/30 paired rounds against both references. The paired native-TS-7
minus Home interval is **+32.3 to +49.7 ms**. This focused admission run was
followed by the full qualified snapshot above; it separately isolates the
changed workload on the same host.

Correctness gates passed the full ReleaseFast checker suite, all 95 benchmark
harness tests, and three untimed cross-compiler audits: 198 CommonJS instance
checks, 132 static-require discovery checks, and 720 graph-type checks, with
zero failures against TS 6.0.3, native TS 7.0.2, and Home. Raw local evidence
is retained under
`bench/vs_tsgo/results/commonjs-import-resolution-cache.20260901T011915Z/`;
the pinned-competitor rounds and provenance are in
`bench/vs_tsgo/results/20260901T012536Z/`.

### Prepared source-marker reuse

Commit `5efbd19df`, tracked in
[#416](https://github.com/home-lang/home/issues/416), removes a duplicate
whole-program source scan. `ts_driver.prepareSource` already builds one exact
multi-pattern marker index per file; Program now borrows that immutable index
for its cross-file discovery pass instead of scanning every source again with
a second matcher. The shared index gained the two Program-only markers,
`interface` and `exports`. Pre-compilation callers retain an owned-index path,
and dropping a compilation clears a borrowed view before freeing its storage.
A regression test verifies that prepared files point at the exact
`Compilation.source_markers` index.

The fixed before binary has SHA-256
`150c2206d8d38990a2d0054d03c8939357960d5a26c0e6c0b9ca560d7fc8581b`;
the accepted candidate is
`0d2aed7253152acb66965e5148d09c5a50bf7512e9062faecee0daa70caa3f60`.
Both exit 0 with byte-identical stdout and stderr on the unchanged 32,768- and
65,536-family predicate projects. Focused marker tests, the full ReleaseFast
Program suite, the full ReleaseFast checker suite, and all 95 benchmark-harness
tests pass.

Each A/B scale used three alternating warmup pairs followed by measured pairs
whose process order reversed every round. Times are untrimmed mean ± sample
standard deviation. The paired interval is for before-minus-after time, so an
interval wholly above zero favors the candidate.

| Source-marker A/B | Metric | Before | After | Speedup | After wins | Paired 95% CI |
|---|---|---:|---:|---:|---:|---:|
| 32,768 families, 20 pairs | Wall | 5389.9 ± 460.6 ms | **4961.4 ± 296.3 ms** | **1.086×** | 19/20 | +242.7 to +614.2 ms |
| 32,768 families, 20 pairs | CPU | 5256.2 ± 355.2 ms | **4856.8 ± 236.2 ms** | **1.082×** | 19/20 | +255.4 to +543.4 ms |
| 65,536 families, 20 pairs | Wall | 10967.9 ± 968.4 ms | **10533.7 ± 979.8 ms** | **1.041×** | 12/20 | +4.4 to +864.0 ms |
| 65,536 families, 20 pairs | CPU | 10703.8 ± 782.2 ms | **10202.3 ± 746.9 ms** | **1.049×** | 16/20 | +187.9 to +815.0 ms |

The 65,536-family wall result is noisy because unrelated builds began during
the run. No sample was removed; both its wall and process-CPU intervals remain
positive. A separate 10-pair screen at 32,768 families also favored the
candidate on wall (1.035×, 9/10, CI +62.7 to +294.8 ms) and CPU (1.047×,
9/10, CI +132.1 to +333.0 ms). Raw A/B evidence is retained in
`bench/vs_tsgo/results/program-source-marker-reuse.Ii55xS/`.

Two marker-index follow-ups were measured and rejected. First, 39 independent
exact `indexOf` searches were compared directly with the single Aho–Corasick
pass on the unchanged 100,993,656-byte source. Each invocation used ten
alternating in-process rounds. The current pass averaged 311.855, 266.118, and
268.457 ms across three invocations; independent searches took 1367.862,
1389.771, and 1424.940 ms. Replacing the combined pass would be roughly five
times slower, so no production candidate was created.

Second, the 244-state automaton was specialized to `u8` transitions while
retaining `u16` for larger generic matcher instantiations. Its direct marker
times improved to 240.446, 250.990, and 240.570 ms, and the focused 3/3 tests
plus exact compiler output at both scales passed. The fixed compiler candidate
(`733a59fe4fcb1cadf0cd5b0c23d2bdb6af9af26499a33230c4c2379e638422b3`)
initially showed a 1.0085× wall and 1.0084× CPU improvement in ten pairs. The
prespecified 20-pair confirmation did not reproduce a reliable whole-compiler
win: wall was 4553.0 ± 160.8 ms before versus 4523.3 ± 139.6 ms after
(1.0066×, 10/20, paired interval -17.5 to +77.0 ms), while CPU was
4529.0 ± 149.5 ms versus 4502.1 ± 135.6 ms (1.0060×, 10/20, interval -13.6
to +67.4 ms). The representation change was fully reverted. Raw rounds remain
under `bench/vs_tsgo/results/source-marker-state-width.iZsnJ1/`.

Two exact prefix-trie replacements were also measured and rejected. Unlike the
39-search probe, each trie still made one outer pass over the source: the first
row stayed hot, and deeper rows were visited only after a real marker prefix.
The second version additionally stored the marker set reachable below each
state so already-found prefix subtrees could be skipped. Isolated ten-round
screens on the unchanged 100,993,656-byte source suggested substantial local
scan savings: the accepted Aho–Corasick binary measured 390.109 ms in that
session, the plain trie 148.670 ms, and the pruned trie 96.587 ms. These
single-binary screens were used only to decide whether to build full compiler
candidates; host load moved between invocations, so they are not acceptance
evidence.

The fixed baseline remained
`0d2aed7253152acb66965e5148d09c5a50bf7512e9062faecee0daa70caa3f60`.
The plain-trie compiler was
`e07847318a52844f4222433db674027b9c2a4604cea3963f496a09c489da2e1c`;
the pruned-trie compiler was
`1657f5c3532fcfd2d4fe97ef3a2754ff62f128fc2c9055f987e5aaa5d619ffbb`.
Both candidates exited 0 with byte-identical stdout and stderr at 32,768 and
65,536 families. The focused marker tests, full ReleaseFast checker suite,
full ReleaseFast Program suite, and all 95 harness tests passed for each
candidate.

Every A/B below used three alternating warmup pairs, reversed process order on
each measured round, and retained every sample. The interval is paired
baseline-minus-candidate time; an interval crossing zero fails admission.

| Trie probe | Metric | Baseline | Candidate | Speedup | Candidate wins | Paired 95% CI |
|---|---|---:|---:|---:|---:|---:|
| Plain trie, 32,768 screen, 10 pairs | Wall | 4823.2 ± 191.1 ms | 4831.4 ± 239.8 ms | 0.9983× | 4/10 | -83.6 to +67.2 ms |
| Plain trie, 32,768 screen, 10 pairs | CPU | 4776.5 ± 165.5 ms | 4774.2 ± 209.0 ms | 1.0005× | 4/10 | -69.9 to +74.5 ms |
| Plain trie, 32,768 confirmation, 20 pairs | Wall | 4827.5 ± 324.7 ms | 4770.7 ± 310.9 ms | 1.0119× | 14/20 | -8.0 to +121.5 ms |
| Plain trie, 32,768 confirmation, 20 pairs | CPU | 4754.0 ± 256.0 ms | 4707.1 ± 269.6 ms | 1.0100× | 13/20 | -8.4 to +102.2 ms |
| Plain trie, 65,536 screen, 10 pairs | Wall | 10054.7 ± 488.8 ms | 9711.8 ± 417.9 ms | 1.0353× | 7/10 | +69.7 to +616.3 ms |
| Plain trie, 65,536 screen, 10 pairs | CPU | 9920.3 ± 424.1 ms | 9597.7 ± 362.6 ms | 1.0336× | 8/10 | +84.3 to +561.0 ms |
| Pruned trie, 32,768 screen, 10 pairs | Wall | 4666.1 ± 238.8 ms | 4628.9 ± 239.4 ms | 1.0080× | 5/10 | -70.4 to +144.7 ms |
| Pruned trie, 32,768 screen, 10 pairs | CPU | 4615.8 ± 206.1 ms | 4561.1 ± 167.1 ms | 1.0120× | 6/10 | -28.9 to +138.2 ms |
| Pruned trie, 65,536 screen, 10 pairs | Wall | 9417.7 ± 179.4 ms | 9318.2 ± 165.7 ms | 1.0107× | 4/10 | -116.6 to +315.6 ms |
| Pruned trie, 65,536 screen, 10 pairs | CPU | 9355.6 ± 162.9 ms | 9252.8 ± 145.2 ms | 1.0111× | 4/10 | -91.5 to +297.0 ms |

The plain trie produced one positive larger-scale screen, but its independent
32,768-family confirmation remained inconclusive. The pruned variant did not
reproduce the larger-scale interval and also remained inconclusive at 32,768.
Neither candidate met the whole-compiler admission rule, so both were fully
reverted and the accepted Aho–Corasick implementation remains in production.
Raw evidence is retained under
`bench/vs_tsgo/results/source-marker-trie.20260831T153305.99359/` and
`bench/vs_tsgo/results/source-marker-pruned-trie.20260831T160024.69935/`.

A parser-local exact-name cache was measured next and rejected. The 64-entry
direct-mapped cache retained source offsets, the exact Wyhash, and the stable
`StringId`; a possible hit still required equal length and full source-byte
equality. A miss used the same precomputed hash for the canonical shared
interner lookup, so identity, ownership, and concurrent publication remained
unchanged. The focused ReleaseFast parser and string-interner suites passed,
and the fixed candidate exited 0 with byte-identical stdout and stderr at both
large scales. Its SHA-256 was
`60ceb2f534ee01859e27f4ac3fabbd6630679b7361e90852f423bbdec087d97a`
against baseline
`0d2aed7253152acb66965e5148d09c5a50bf7512e9062faecee0daa70caa3f60`.

The 32,768-family screen used three alternating warmup pairs and ten measured
pairs with reversed order and no filtering. Wall time was 4716.3 ± 154.9 ms
for the baseline versus 4721.7 ± 276.3 ms for the candidate (0.9989×, 5/10
candidate wins, paired interval -123.8 to +112.9 ms). Process CPU was
4665.3 ± 127.3 ms versus 4666.0 ± 234.1 ms (0.9999×, 5/10, interval -99.6
to +98.2 ms). The initial gate failed, so no confirmation or 65,536 timing was
run. The cache and prehashed public API were fully reverted. Raw evidence is
retained under
`bench/vs_tsgo/results/parser-local-interner-cache.20260831T162449.18110/`.

Conservative source-marker gates around declaration-space sibling passes were
also measured and rejected. The candidate skipped namespace, class/interface,
enum, or type-alias merge scans only when attached source made that declaration
kind impossible; marker false positives retained the existing scan, and
source-less checker callers retained every pass. The merge-focused ReleaseFast
checker gate passed, and the fixed compiler produced byte-identical output at
both large scales. Candidate SHA-256 was
`41b9d70b977818d1548ae375d98ff3858a4a02e266b11c40130babfc6b984ad5`
against baseline
`0d2aed7253152acb66965e5148d09c5a50bf7512e9062faecee0daa70caa3f60`.

The 32,768-family initial screen retained all ten reversed-order pairs after
three alternating warmup pairs. Wall time regressed from 4699.2 ± 166.2 ms to
4810.0 ± 287.3 ms (0.9770×, 3/10 candidate wins, paired interval -318.8 to
+97.1 ms). Process CPU moved from 4656.6 ± 143.0 ms to 4736.5 ± 221.4 ms
(0.9831×, 3/10, interval -248.6 to +88.7 ms). The initial gate failed, so no
confirmation or 65,536 timing was run; the gates were fully reverted. Raw
evidence remains under
`bench/vs_tsgo/results/declaration-pass-gates.20260831T163650.42200/`.

After accepting the program import-resolution cache, a fresh sample of the
current binary on the unchanged 32,768-family predicate project confirmed that
the earlier source-preparation hotspot had moved: `ts_driver.prepareSource`
fell from 316 to 23 exclusive samples. Repeated structural annotation lookup
was now visible at 68 exclusive samples in
`visibleAnnotatedIdentifierTypeNode`. A 256-entry checker-local direct-mapped
cache was tested for that exact `(identifier node -> annotation node or miss)`
query. Hits verified the full NodeId, collisions used the unchanged parent
walk, the cache allocated no memory, and source or bound-module replacement
cleared every slot.

The fixed accepted baseline was
`ec99b3fcca63f39d97f147bbe2ad5139bf5e53a22f885e25bd1f6eb971386789`;
the cache candidate was
`5e0969b8ee1cf0fb2716e40678327f6e99a346aa26c16ed50f8c906f9b818353`.
Both exited 0 with byte-identical empty stdout and stderr on the 32,768-family
project, and the focused ReleaseFast type-predicate checker gate passed. The
screen retained all ten reversed-order pairs after three alternating warmup
pairs. Wall time was 5155.6 ± 318.3 ms for the baseline versus
5175.6 ± 235.3 ms for the candidate (0.9961×, 5/10 candidate wins, paired
interval -295.3 to +255.3 ms). Process CPU was 5024.3 ± 250.2 ms versus
5014.0 ± 151.9 ms (1.0021×, 5/10, interval -181.4 to +202.1 ms). Both
intervals cross zero and wall mean regressed, so the cache was fully reverted
without a confirmation or larger-scale run. Raw evidence remains under
`bench/vs_tsgo/results/visible-annotation-hot-cache.20260901T020323Z/`; the
fresh accepted-binary profile is under
`bench/vs_tsgo/results/predicate-current-profile.20260901T014600Z/`.

### Dependency-free declaration schemas

Commit `e0f2fb6d7`, tracked in
[#416](https://github.com/home-lang/home/issues/416), avoids constructing the
program declaration-schema graph when the resolved program has no file
dependencies. Those schemas transfer types across file boundaries. A program
with no resolved dependency has no cross-file consumer: local declarations
continue through their owner's HIR and symbol tables, global scripts use the
bound-global index, and CommonJS uses its separate program facts. Any resolved
file dependency retains the complete existing collector. The full export
snapshot helper is also unchanged for callers that explicitly request it.

The regression proves both sides of that boundary. Checking-time collection is
empty for a dependency-free generic module, while its explicit export snapshot
still contains the factory value and interface type. A full check retains local
generic inference, emits the deliberate TS2322 control, and does not emit the
TS2304 missing-name failure. The ReleaseFast Program suite, focused
type-predicate checker suite, all **95/95** harness tests, and every positive and
negative admission gate for all 20 benchmark workloads pass.

The immutable baseline is SHA-256
`ec99b3fcca63f39d97f147bbe2ad5139bf5e53a22f885e25bd1f6eb971386789`;
the accepted candidate is
`83f48045ba8dc697177eb2d6d453409cb06ae44167d094b6d70ed6e1dec25e7e`.
Both exit zero with byte-identical empty stdout and stderr on the official
2,048-family predicate workload and unchanged 32,768- and 65,536-family scale
projects. The official `recursive_generics` output is also exact.

The decisive unchanged official `type_predicates_large` A/B retained all 30
reversed-order pairs after three alternating warmup pairs. No sample was
filtered. Wall time falls from **258.315 ± 7.221 ms** to
**246.859 ± 4.718 ms** (**1.0464×**, 30/30 candidate wins), with a paired 95%
interval of **+9.586 to +13.325 ms**. Process CPU falls from
**256.033 ± 7.037 ms** to **244.838 ± 4.605 ms** (**1.0457×**, 30/30), with
an interval of **+9.428 to +12.962 ms**.

The noisy larger-scale screens are retained rather than pooled or trimmed.
At 32,768 families, wall measured 4498.5 ± 291.2 ms versus
4511.5 ± 502.2 ms and CPU measured 4456.8 ± 252.2 ms versus
4389.7 ± 341.0 ms; both paired intervals cross zero. At 65,536 families, the
candidate has lower means—10363.7 ± 621.5 ms versus 10156.9 ± 1021.6 ms wall,
and 10160.0 ± 414.0 ms versus 9975.6 ± 900.0 ms CPU—but both intervals again
cross zero. The short `recursive_generics` confirmation is also neutral. These
secondary observations neither strengthen nor weaken the accepted standard
workload result. Raw evidence is under
`bench/vs_tsgo/results/dependency-free-declarations.20260901T022352Z/`.

### Source-marker root-gap fast-forward

Commit `7ca9946c8`, tracked in
[#416](https://github.com/home-lang/home/issues/416), keeps the accepted exact
Aho–Corasick source-marker matcher and fast-forwards only gaps that are proven
to remain at its root. The matcher computes the distinct first bytes of every
registered marker at compile time. While the automaton is at state zero,
`std.mem.indexOfAnyPos` skips to the next possible first byte in bulk. Every
possible prefix, failure transition, overlapping match, suffix match, and
first-occurrence position still uses the unchanged automaton. This is not the
previous rejected trie replacement and does not add a semantic feature gate.

The immutable accepted baseline is SHA-256
`83f48045ba8dc697177eb2d6d453409cb06ae44167d094b6d70ed6e1dec25e7e`;
the root-gap candidate is
`60e10affa923acd3265511f91f248277cf7bbf70e28508ff1bf903b8761bf2a2`.
Both exit zero with byte-identical empty stdout and stderr on the official
2,048-family and unchanged 65,536-family predicate projects. The focused exact
marker tests, full ReleaseFast checker, driver, and Program suites, all
**95/95** harness tests, and every positive and negative admission gate for all
20 workloads pass.

The unchanged official `type_predicates_large` A/B retained all 30
reversed-order pairs after three alternating warmup pairs. No sample was
filtered. Wall time falls from **240.611 ± 3.256 ms** to
**237.311 ± 5.460 ms** (**1.0139×**, 27/30 candidate wins), with a paired 95%
interval of **+1.558 to +5.040 ms**. Process CPU falls from
**238.928 ± 3.153 ms** to **235.592 ± 4.990 ms** (**1.0142×**, 26/30), with
an interval of **+1.716 to +4.956 ms**.

The independent 65,536-family screen retained all ten pairs with the starting
order reversed. Wall falls from 8747.426 ± 109.663 ms to
8626.257 ± 116.604 ms (**1.0140×**, 8/10), with a paired interval of
**+40.535 to +201.804 ms**. Process CPU falls from
8715.280 ± 81.749 ms to 8591.872 ± 96.556 ms (**1.0144×**, 9/10), with an
interval of **+65.075 to +181.743 ms**. Raw exact outputs and every A/B round
remain under
`bench/vs_tsgo/results/source-marker-root-skip.20260901T025847Z/`.

The independent focused three-compiler checkpoint `20260901T031352Z` compares
version-verified TS 6.0.3, native TS 7.0.2, and the latest immutable Home binary:

| Focused `type_predicates_large` | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| 30 interleaved rounds | 1242.7 ± 414.8 ms | 413.2 ± 84.6 ms | **267.8 ± 36.4 ms** | **1.54× faster** |

Home beats native TS 7 in 29/30 focused pairs and TS 6 in 30/30. The paired
native-TS-7-minus-Home 95% interval is +111.6 to +179.2 ms. All 30 round files
/ 90 successful finite samples are retained, and compiler provenance is
unchanged before and after measurement. The immediately preceding complete
20-workload checkpoint is the [current snapshot](#current-snapshot); all 20
admission gates pass on this newer binary, while its focused timing remains
separate rather than replacing or being pooled with that full checkpoint.

### Rejected larger string-interner hint

The post-root-gap profile still showed the shared string interner as a material
owned cost, so its existing exact 64-entry direct-mapped hint was tested at 256
entries per shard. This is distinct from the earlier rejected parser-local
cache: it changes only the capacity of the canonical shared hint. Every
possible hit still takes the shard lock and verifies full byte equality; every
miss still uses the unchanged prehashed canonical table. The tested size would
increase total hint storage from 32 KiB to 128 KiB.

The immutable baseline is SHA-256
`60e10affa923acd3265511f91f248277cf7bbf70e28508ff1bf903b8761bf2a2`;
the fixed 256-entry candidate is
`793144e3a19604c96673c97d42fdf6d63a93ba27fc48b8615841adea73165b1e`.
Both exit zero with byte-identical empty stdout and stderr on the official
2,048-family and unchanged 32,768-family predicate projects. The ReleaseFast
string-interner suite also passes.

The 32,768-family screen retained all ten reversed-order pairs after three
alternating warmup pairs, with no filtering. Wall time regressed from
7727.518 ± 414.303 ms to 8069.492 ± 701.373 ms (0.9576× baseline/candidate,
4/10 candidate wins), with a baseline-minus-candidate paired 95% interval of
-706.254 to +22.306 ms. Process CPU regressed from 6215.600 ± 107.917 ms to
6307.875 ± 115.115 ms (0.9854×, 4/10), with an interval of -209.220 to
+24.670 ms. The initial gate therefore failed; no confirmation was run, and
the 64-entry production capacity was restored. Raw exact outputs, binaries,
and every measured pair remain under
`bench/vs_tsgo/results/string-interner-cache-capacity.20260901T033000Z/`.

### Rejected special-identifier classification

The same post-root-gap profile attributed part of `mem.eqlBytes` to
`typeOfIdentifier`, which tests ordinary names against `this`, `await`,
`arguments`, and `new.target` along different fallback paths. An exact probe
classified those mutually exclusive spellings once by length plus full byte
equality and reused the result in the existing branches. It added no cache or
feature gate and did not change lookup or diagnostic order.

The immutable baseline is SHA-256
`60e10affa923acd3265511f91f248277cf7bbf70e28508ff1bf903b8761bf2a2`;
the fixed candidate is
`340bcab7683acf3ab4e1b951c13dc6814818e036535fae4c65904e24d4a19721`.
Both exit zero with byte-identical empty stdout and stderr on the official
2,048-family and unchanged 32,768-family predicate projects.

The official-workload screen retained all ten reversed-order pairs after three
alternating warmup pairs, with no filtering. Wall measured
246.588 ± 9.418 ms for the baseline versus 243.908 ± 5.698 ms for the
candidate (1.0110×, 6/10 candidate wins), with a paired 95% interval of
-6.114 to +11.473 ms. Process CPU measured 244.176 ± 8.272 ms versus
241.710 ± 5.238 ms (1.0102×, 6/10), with an interval of -5.188 to
+10.121 ms. The means were lower but neither interval nor pair direction
cleared the initial gate, so no larger-scale timing or confirmation was run and
the probe was fully reverted. Raw binaries, exact outputs, and every screen
round remain under
`bench/vs_tsgo/results/special-identifier-classification.20260901T035000Z/`.

### Rejected declaration-map pre-sizing

`checkDeclarationSpaceDiagnosticsImpl` owns three temporary hash maps for
ordinary declaration collisions, interface merges, and function
implementations. A semantic-neutral probe counted the corresponding HIR
declaration kinds, reserved each map's final upper-bound capacity, and then ran
the unchanged diagnostic passes and insertion logic. The additional count was
linear, allocation failure remained explicit, and diagnostic contents and
order were unchanged.

The immutable baseline is SHA-256
`60e10affa923acd3265511f91f248277cf7bbf70e28508ff1bf903b8761bf2a2`;
the fixed candidate is
`c01cd4bf76e85650830292dc52d6ed958bf6166ca34ff6586695cfd2735b9dde`.
Both exit zero with byte-identical empty stdout and stderr on the official
2,048-family predicate project.

The initial screen retained ten reversed-order pairs after three alternating
warmup pairs, with no filtering. Wall measured 327.868 ± 16.578 ms versus
318.948 ± 17.585 ms (1.0280×, 8/10 candidate wins), but its paired 95%
interval was -10.141 to +27.981 ms. CPU measured 316.272 ± 13.006 ms versus
307.522 ± 9.762 ms (1.0285×, 8/10), with an interval of -2.358 to
+19.858 ms. That signal admitted an independent confirmation; it was not
pooled with the screen.

The confirmation retained all 30 reversed-order pairs after a fresh set of
three alternating warmup pairs. Wall measured 250.214 ± 9.998 ms versus
248.246 ± 13.890 ms (1.0079×, 23/30), with a paired interval of -3.764 to
+7.700 ms. CPU measured 246.950 ± 8.510 ms versus
244.955 ± 10.931 ms (1.0081×, 24/30), with an interval of -2.315 to
+6.305 ms. The independent confirmation did not clear the paired-mean rule,
so the probe was fully reverted and no scale timing was run. Raw binaries,
exact output, and every screen and confirmation round remain under
`bench/vs_tsgo/results/declaration-map-presize.20260901T041500Z/`.

### Rejected identifier declaration-slot reuse

The accepted profile showed material exclusive time in `typeOfIdentifier`.
That function can ask whether the same immutable HIR node is a declaration
name at many fallback branches, so an exact probe evaluated
`isDeclNameSlot(node)` once at its first use and reused the boolean in the 36
later branches. Early `await`, private-name, constructor-field, and `this`
exits remained before the computation. No cache, semantic gate, lookup
reordering, or diagnostic reordering was introduced.

The immutable baseline is SHA-256
`60e10affa923acd3265511f91f248277cf7bbf70e28508ff1bf903b8761bf2a2`;
the fixed candidate is
`6df9a6db988911be719b9f0079296fa815b18a6d0e17d60e629140472de37b81`.
Both exit zero with byte-identical empty stdout and stderr on the official
2,048-family and unchanged 32,768-family predicate projects.

The official-workload screen retained all ten reversed-order pairs after three
alternating warmup pairs, with no filtering. Wall time regressed from
292.454 ± 28.421 ms to 300.577 ± 30.022 ms (0.9730× baseline/candidate,
4/10 candidate wins), with a paired 95% interval of -33.078 to +16.832 ms.
Process CPU was effectively flat to worse at 283.171 ± 19.615 ms versus
284.514 ± 15.643 ms (0.9953×, 5/10), with an interval of -19.859 to
+17.172 ms. The initial gate failed, so no confirmation or scale timing was
run and the probe was fully reverted. Raw binaries, exact outputs, and every
screen round remain under
`bench/vs_tsgo/results/identifier-decl-slot-reuse.20260901T035734Z/`.

### Rejected parser identifier escape-flag reuse

The scanner already records whether an identifier token contains a consumed
Unicode escape. `internToken` nevertheless searched the raw identifier slice
again for `\\` before entering its existing escape decoder. A one-line exact
probe reused `TokenFlags.has_escape` for that decision while retaining the
same `.identifier` kind guard, decoder, allocation fallback, and interner call.
Scanner behavior and token layout were unchanged.

The immutable baseline is SHA-256
`60e10affa923acd3265511f91f248277cf7bbf70e28508ff1bf903b8761bf2a2`;
the fixed candidate is
`59beef049b14e6a8ebc314f1c7ff408f96d3e6d43052d447436b120e63081c56`.
Both exit zero with byte-identical empty stdout and stderr on the official
2,048-family and unchanged 32,768- and 65,536-family predicate projects. The
full ReleaseFast parser suite passes, including bare identifiers, `\\uXXXX`,
brace-form escapes, escaped enum members, and invalid escaped starts.

The official-workload screen retained all ten reversed-order pairs after three
alternating warmup pairs, with no filtering. Wall time regressed from
440.866 ± 24.461 ms to 452.033 ± 25.669 ms (0.9753× baseline/candidate,
5/10 candidate wins), with a paired 95% interval of -34.149 to +11.814 ms.
Process CPU regressed from 377.824 ± 11.665 ms to 383.668 ± 19.005 ms
(0.9848×, 5/10), with an interval of -24.280 to +12.592 ms. The initial gate
failed, so no confirmation or scale timing was run and the probe was fully
reverted. Raw binaries, exact outputs, and every screen round remain under
`bench/vs_tsgo/results/parser-escape-flag-reuse.20260901T040925Z/`.

## Linux ARM64 container checkpoint

Measured 2026-08-29 at commit `6ac9b5e59` in a pinned Debian Bookworm
container on a native Linux ARM64 ext4 volume. The host was an Ubuntu 26.04
ARM64 Lima/VZ VM with 4 vCPUs and 8 GB RAM; the measured container reported
Linux 7.0.0-28-generic, aarch64, and glibc 2.36. The container image is
`node:24.18.0-bookworm-slim` at digest
`sha256:6f7b03f7c2c8e2e784dcf9295400527b9b1270fd37b7e9a7285cf83b6951452d`,
with Node 24.18.0, Hyperfine 1.20.0, and Python 3.11.2. The complete raw-result
identifier is `20260829T035150Z`.

The same admission rules, generated corpus, and 30-round interleaved schedule
were used with TS **6.0.3**, native TS **7.0.2**, and Home. All **600 round
files / 1,800 successful finite samples** are retained without filtering.
Compiler and tool provenance was hashed before admission and again after
measurement. The Home ARM64 ReleaseFast binary has SHA-256
`9512c02505248c031beb75ab304e65bde9e018bf93d340adf56bd164a5eb31bb`.

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `checkjs_jsdoc` | 241.3 ± 9.7 ms | 38.0 ± 1.4 ms | **37.3 ± 0.9 ms** | **1.02× faster; narrow** |
| `class_hierarchy` | 208.0 ± 2.7 ms | 35.5 ± 1.1 ms | **28.1 ± 0.3 ms** | **1.27× faster** |
| `commonjs_graph` | 162.9 ± 2.9 ms | 29.1 ± 1.4 ms | **27.7 ± 0.6 ms** | **1.05× faster** |
| `control_flow` | 221.3 ± 6.1 ms | 42.8 ± 1.5 ms | **36.3 ± 4.1 ms** | **1.18× faster** |
| `deep_types` | 137.4 ± 2.6 ms | 34.3 ± 1.0 ms | **25.0 ± 0.3 ms** | **1.37× faster** |
| `destructuring` | 155.3 ± 2.6 ms | 30.4 ± 1.3 ms | **19.5 ± 0.3 ms** | **1.56× faster** |
| `generic_calls` | 202.2 ± 2.7 ms | 38.0 ± 0.9 ms | **21.9 ± 0.5 ms** | **1.74× faster** |
| `import_graph` | 149.1 ± 47.3 ms | 28.7 ± 5.3 ms | **20.9 ± 1.3 ms** | **1.37× faster** |
| `interface_composition` | 235.6 ± 23.6 ms | 47.5 ± 1.6 ms | **44.6 ± 0.9 ms** | **1.07× faster** |
| `many_files` | 230.1 ± 29.7 ms | 35.5 ± 3.2 ms | **22.4 ± 0.7 ms** | **1.58× faster** |
| `null_safe_access` | 223.8 ± 8.9 ms | 42.0 ± 1.0 ms | **40.7 ± 0.8 ms** | **1.03× faster; narrow** |
| `overload_resolution` | 233.6 ± 3.3 ms | 49.1 ± 2.4 ms | **29.7 ± 0.8 ms** | **1.65× faster** |
| `recursive_generics` | 159.6 ± 2.9 ms | 54.5 ± 1.0 ms | **27.5 ± 0.2 ms** | **1.98× faster** |
| `reexport_graph` | 97.7 ± 3.0 ms | 22.2 ± 1.1 ms | **11.8 ± 0.6 ms** | **1.88× faster** |
| `startup` | 52.9 ± 1.1 ms | 17.9 ± 0.8 ms | **0.8 ± 0.1 ms** | **21.67× faster** |
| `structural_objects` | 212.2 ± 3.6 ms | 42.1 ± 1.4 ms | **29.3 ± 0.5 ms** | **1.44× faster** |
| `tsx_components` | 180.5 ± 2.9 ms | 29.6 ± 0.9 ms | **21.7 ± 0.4 ms** | **1.37× faster** |
| `type_predicates` | 283.4 ± 3.8 ms | 57.0 ± 0.9 ms | **44.3 ± 0.5 ms** | **1.29× faster** |
| `type_predicates_large` | 1181.5 ± 27.8 ms | 388.4 ± 13.8 ms | **355.5 ± 12.2 ms** | **1.09× faster** |
| `variadic_tuples` | 316.4 ± 68.2 ms | 67.0 ± 7.5 ms | **47.2 ± 7.5 ms** | **1.42× faster** |

Home records lower means on **20/20 admitted workloads** in this Linux
checkpoint. The narrow CheckJS row has 19/30 paired wins and medians of 37.0
ms for Home versus 37.6 ms for the fastest competitor; it is documented as a
narrow result, not a universal claim. Null-safe access has 25/30 paired wins
and CommonJS has 27/30. All other rows have at least 29/30 paired wins.

## Fairness and measurement

- Compiler versions are pinned in `bench/vs_tsgo/corpus.toml`. The runner rejects
  an installed TS 6 or TS 7 version that differs from its exact pin before
  recording results; rerun `setup` after changing a pin. Native TS 7 is the
  single `tsgo` entry, not an additional competitor.
- JavaScript TypeScript 6 and native TypeScript 7 are installed in separate
  tool prefixes so npm cannot replace one implementation with the other.
- The corpus is generated deterministically and is shared by all compilers.
- Every command receives `--noEmit -p <same tsconfig.json>`.
- Every project enables `strict`, `noLib`, `skipLibCheck`, and `pretty: false`.
  `noLib` isolates frontend work from differences in bundled standard-library
  size and availability.
- Before timing, every compiler must exit successfully without stdout or
  stderr. A compiler cannot win by rejecting or skipping the input.
- Destructuring also has five automatic negative controls in an untimed
  temporary project copy: nested properties, tuple elements, object-rest
  fields, defaults, and omitted rest properties must produce exactly four
  `TS2322` diagnostics and one `TS2339` in every compiler.
- Both predicate sizes have four automatic controls inside the guard branch and
  after the assertion call. Invalid narrowed-property assignments and reads
  of excluded union members must produce two `TS2322` and two `TS2339`
  diagnostics in every compiler, using an untimed temporary project copy.
- Both ES-module graphs must reject a wrong imported-property assignment and a
  missing-member read. Variadic tuples have equivalent tuple-element controls.
- `commonjs_graph` uses a temporary copy and requires exactly three `TS2322`
  and three `TS2339` diagnostics, distributed across the first, middle, and
  last checked owner. Timing cannot begin, or create its result directory,
  unless every selected workload passes every applicable control in all three
  compilers.
- Measurements are process-cold and filesystem-cache-warm. Each timed sample
  launches a new compiler process after explicit warmups.
- A measured round contains all three compilers. Their order rotates each round
  so changing workstation load cannot consistently favor one implementation.
- Hyperfine supplies the process timer. Reported uncertainty is the sample
  standard deviation, not a confidence interval.

The Linux checkpoint uses the repository Dockerfile from the repository root.
The root `.dockerignore` limits the build context to the entrypoint, while the
repository and a native Linux ReleaseFast `home-tsc` are mounted at runtime.
The benchmark workspace must live on a native Linux filesystem; macOS-shared
VirtioFS measurements are diagnostic only because their file-access behavior
is not representative. The entrypoint installs the exact manifest pins,
regenerates the corpus, runs admission, and then measures. This container path
is tracked in [issue #464](https://github.com/home-lang/home/issues/464).

## Workloads

| Workload | Generated shape | Cost represented |
|---|---:|---|
| `startup` | One small source file plus a minimal declaration file | CLI and frontend startup |
| `many_files` | 256 independent source files plus a minimal declaration file | File discovery, loading, scheduling, parsing, and checking many modules |
| `deep_types` | One source file with 240 repeated generic models | Conditional, mapped, indexed, recursive, and template-literal type work |
| `import_graph` | 128 modules in a relative-import chain | Module resolution, export lookup, import closure, and cross-file generic checking |
| `reexport_graph` | 64 leaf modules projected through eight barrels | Recursive export-star projection, module resolution, and ambiguity checking |
| `tsx_components` | One module with 256 typed generic component declarations and JSX trees | TSX scanning, parsing, contextual props, expressions, and checking |
| `generic_calls` | One module with 256 typed generic call groups | Constrained inference, `keyof`, indexed access, mapped returns, and contextual callbacks |
| `control_flow` | One module with 256 exhaustive discriminated-union functions | Narrowing, branch joins, definite assignment, exhaustive switches, property reads, and typed object returns |
| `type_predicates` | One module with 256 independent predicate families | User-defined type predicates, assertion functions, call-driven narrowing, nested property reads, and typed consumption |
| `type_predicates_large` | The identical generator with 2,048 independent predicate families | Scaling behavior at eight times the original size, with the same feature mix, compiler options, and negative controls |
| `null_safe_access` | One module with 256 independent nullable object families | Optional property, element, and call chains, nullish coalescing, non-null assertions, and typed consumption |
| `destructuring` | One module with 128 independent object families | Nested object and tuple bindings, defaults, object rest, spread reconstruction, and typed consumption |
| `overload_resolution` | One module with 128 groups of eight typed overload calls | Literal-discriminated overload selection, generic inference, object and tuple payloads, callbacks, and typed result consumption |
| `class_hierarchy` | One module with 128 independent generic base/derived/interface families | Class heritage resolution, generic substitution, constructors, overrides, protected members, interface compatibility, and typed instance consumption |
| `structural_objects` | One module with 128 independent source/target object families | Nested structural compatibility, optional and readonly members, tuples, intersections, generic function properties, excess source members, assignments, and typed argument passing |
| `interface_composition` | One module with 128 independent generic interface and namespace families | Multi-base interface heritage, repeated declaration merging, namespace/type/value merging, nested exported interfaces, generic functions, structural values, and typed consumption |
| `variadic_tuples` | One module with 256 independent readonly tuple families | Variadic tuple concat, readonly inference, conditional head/tail extraction, generic rest and spread, indexed reads, and typed consumption |
| `checkjs_jsdoc` | One checked-JavaScript module with 128 independent JSDoc families | JSDoc typedefs, constrained templates, callbacks, classes, property reads, and typed consumption |

The suite intentionally uses dependency-free synthetic projects so its inputs
stay stable and auditable. It does not replace benchmarks of pinned real-world
applications. A real project belongs in the suite only when all three compilers
can validate the same source graph and configuration.

## Reproduce

From the repository root:

```sh
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
./bench/vs_tsgo/run.sh setup
./bench/vs_tsgo/run.sh corpus
./bench/vs_tsgo/run.sh cold --runs 30 --warmup 3
./bench/vs_tsgo/run.sh report
```

The harness records compiler versions, host metadata, timing configuration,
and raw per-round Hyperfine JSON under
`bench/vs_tsgo/results/<UTC timestamp>/`. Results are ignored by Git because
they are machine-specific; the reviewed snapshot above is the durable record.

An independent confirmation of a selected workload uses the same validation
and interleaved timing rules:

```sh
./bench/vs_tsgo/run.sh cold --runs 30 --warmup 3 --workload type_predicates_large
```

The selection is recorded in metadata. Repeat `--workload` to select several
cases; omitting it runs the full suite. Targeted runs supplement the full
report, never replace it or justify discarding an earlier result.

## Improvements behind this result

The current result comes from general compiler changes rather than
workload-specific shortcuts:

- release builds use the production thread-safe allocator while Debug retains
  leak detection;
- parser and checker feature probes cache source-level facts instead of
  repeatedly scanning whole files;
- identifier scanning tests the common ASCII continuation case before the
  UTF-8 whitespace tables, while escaped identifiers and non-ASCII whitespace
  retain their complete scanner paths;
- builtin object-type lowering uses an exact index of the 44 supported names
  to reject ordinary user-defined names before the specialized recipe chain;
- driver preparation computes the exact source-marker index once and reuses it
  for conservative directive/reference gates and checker source facts;
- JSDoc and triple-slash reference presence reuse the existing one-pass source
  marker index instead of rescanning large files;
- visible type declarations are indexed per lexical scope while retaining the
  original resolver as an allocation-failure fallback;
- source loading reuses one I/O runtime per compilation;
- string interning computes Wyhash once and reuses it for shard selection,
  optimistic lookup, write-lock verification, and insertion;
- module resolution reuses one filesystem runtime, preserves extension order
  while snapshotting directories, and caches repeated package-boundary queries;
- optimized builds compile sufficiently large programs with a bounded worker
  pool, while small programs remain serial to avoid thread startup overhead;
- cross-file export queries reuse bind-only module analyses and immutable
  per-export answers;
- resolver mutation is synchronized separately from export-analysis caches so
  independent cache misses can parse and bind concurrently;
- export-star ambiguity checks enumerate and cache real projected names instead
  of rescanning modules or guessing from the number of barrel declarations;
- JSX namespace, pragma, and source-feature probes reuse immutable per-source
  facts; and
- recovered parameter annotations are indexed from actual HIR parameter nodes,
  reusing interned parameter names and excluding object-property lookalikes
  while retaining the same source-syntax validation;
- identifier resolution skips evolving-`any` flow walks when the source has no
  eligible declarations, reuses its lexical annotation lookup, and avoids
  declaration scans for function-arity checks against non-callable targets;
- checker compatibility paths use conservative source-feature facts to skip
  impossible UMD, import, CommonJS, namespace, class, enum, and expando scans;
- simple annotated bindings and their active lexical lookups reuse indexed,
  virtual-section-aware declarations and already-resolved types for ordinary
  reads while declared-type lookups retain their full semantic path;
- overload resolution rejects definite exact-literal mismatches before generic
  inference and substitution, while composite, contextual, spread, enum, and
  ambiguous candidates retain the complete resolver; and
- successful class heritage instance, static, and constructor resolutions are
  cached by extends expression while unresolved and forward-reference paths
  retain the complete resolver;
- conservative source facts skip impossible enum and JavaScript prototype
  searches, `this` and `super` member assignments avoid irrelevant function
  expando discovery, and top-level annotation lookup reuses the existing
  virtual-section-aware declaration index; and
- DOM library availability is computed once per source and reused while
  lowering annotations, preserving `@noLib`, `reference lib`, and explicit
  `@lib` semantics without repeatedly scanning the entire file; and
- named types maintain a validated reverse display-name index instead of
  repeatedly iterating the complete forward name table;
- visible namespaces and simple annotated declarations reuse lexical,
  virtual-section-aware indexes, including a conservative dotted-namespace
  fact that avoids impossible fallback scans;
- interface declaration merging records the real predecessor chain so generic
  and non-generic back-patching touches only declarations in the merge; and
- module augmentation, type-alias, and class/interface compatibility paths use
  syntax facts before performing root-level searches, while allocation failure
  retains the original semantic resolver; and
- program-level declaration, namespace, interface, class, and CommonJS
  collectors skip files whose source cannot contain the syntax they collect;
- generic-instantiation inference skips parameters without free type variables,
  while the full recursive inference path remains active for inferable pairs;
- visible same-name values are indexed by lexical container and virtual source
  section;
- function-expando and plain-import recovery stop before scope walks when HIR
  or source facts prove the relevant syntax is absent; and
- checked-JavaScript analysis indexes named JSDoc declarations, prior typed
  assignments, annotated values, and owning functions; reuses immutable
  typedef and callback types; and skips prototype, import, expando, and
  accessibility searches only when exact source facts prove they cannot apply;
- JSDoc parser diagnostics discover tags once per comment and run only the
  semantically applicable validation passes, preserving every individual
  diagnostic scanner for comments that contain its triggering tag; and
- object-rest inference avoids source-annotation recovery only when the source
  binding is already semantically proven non-nullish, retaining the complete
  recovery path for nullable and ambiguous declarations;
- type aliases and parameter annotations use exact-name indexes, root variable
  recovery reuses binder declarations, and direct named object types reuse
  their reverse display-name mapping and successful structural-name matches;
- CommonJS detection matches `require` as an identifier rather than a
  substring, while import, class, enum, namespace, and type-declaration
  fallbacks stop only when conservative source facts make the search
  impossible;
- source-annotation recovery stops when the nearest lexical parameter and its
  following source token prove there is no annotation to recover, while
  explicit annotations, comments, destructuring, and ambiguous syntax retain
  the complete fallback;
- source-function ownership uses sorted nested function spans for first-time
  position queries, preserving the original full scan for malformed crossing
  ranges or allocation failure and the original NodeId tie-breaking; and
- source-parameter recovery lazily caches immutable containment ranges per
  annotation candidate instead of repeating raw source scans for each use,
  with exhaustive position-pair equivalence and source-reset tests; and
- unsuccessful named-object-shape searches are cached separately for each
  class-preference mode, with a generation guard that expires misses when
  a type name is inserted or rebound; and
- function-declaration lookup indexes the first eligible binding per statement
  container, preserving caller scope walks and binder precedence and retaining
  the original scanner on allocation failure;
- named-shape lookup indexes necessary member facts at type-name registration,
  rejecting impossible searches while retaining the original full comparison
  for possible matches, stale facts, and hash collisions;
- member facts also identify candidate names, using the smallest queried
  bucket; unique full matches return directly, while ambiguous matching names
  retain the original table scan and diagnostic-name order;
- local value-declaration lookup indexes first bindings and exact statement
  boundaries per container and virtual section, preserving the original scan
  on allocation failure;
- exact type-name fallback skips never-registered TypeIds using monotonic
  membership, preserving scan order for possible matches and disabling the
  filter if an allocation fails;
- builtin-name membership uses a compile-time static lookup over the unchanged
  spelling list, retaining source-dependent exceptions; and
- `instanceof` fallthrough-join analysis stops before flow and annotation
  lookup when the existing one-pass source marker index proves that spelling
  cannot occur, while sources containing it retain the complete semantic path;
- one- and two-statement lexical containers use the existing bounded direct
  annotated-value scan instead of allocating two persistent hash-index entries,
  while larger containers retain the indexed path and allocation failures still
  retain the direct resolver;
- the lockless relation cache retains a 4,096-entry working set and inserts new
  relations with one hash-table probe instead of two; both relation-cache
  levels reclaim deletion tombstones at existing FIFO eviction boundaries.

### Recovered-parameter index checkpoint

Commit `18bd0c4ee`, tracked by
[#416](https://github.com/home-lang/home/issues/416), replaces the recovered
parameter index's whole-source identifier scan with iteration over actual HIR
parameter nodes. It retains the existing ASCII name, optional marker, type
identifier, and declaration-delimiter checks. The checker reuses each
parameter's interned HIR name, interns only its recovered type name, and no
longer admits object-property syntax as a candidate before containment
filtering.

The isolated Home A/B uses the unchanged 16,384-family predicate stress project
and identical compiler arguments. The exact published strict-marker binary
(SHA-256 `ba83523099e133f1aab69283304f3568c31f947069c29455b849b70eca01b5b6`)
is the baseline; the candidate binary has SHA-256
`faccb14ac520cd8a37d14246635089d36345ddf3c6d40d8630c59fcf5a73849e`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round. All 40 finite samples are retained.

| 16,384 predicate-family Home A/B | Whole-source baseline | Parameter-node index | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Same project and settings | 2749.3 ± 27.7 ms | **2717.8 ± 33.4 ms** | **1.0116×** | **16/20 pairs** |

The mean paired reduction is 31.5 ms with a 95% paired t confidence interval of
11.7–51.4 ms; the exact two-sided sign-test result is `p = 0.0118`. A fresh
1 ms sampling profile reduces
`recoveredSourceParameterAnnotationType` leaf samples from 31 to 10; candidate
index construction is below the report's five-sample display threshold. These
diagnostics explain the mechanism; the official cross-compiler results reported
above remain the publication gate.

The independent 30-round confirmation is `20260831T000811Z`: TS 6.0.3 takes
1048.0 ± 23.2 ms, native TS 7.0.2 takes 365.3 ± 6.8 ms, and Home takes
**322.0 ± 5.1 ms**, a **1.13×** lead with 30/30 paired wins. The complete
post-index 20-workload result is `20260831T000957Z`: Home has the lower mean
on 20/20 rows and the lower individual time in 599/600 rounds. Both runs
preserve all samples and verify compiler artifacts before admission and after
measurement; they remain a separate checkpoint rather than being pooled with
the current snapshot.

### `instanceof` fallthrough marker checkpoint

Commit `238cc88fc`, tracked by
[#416](https://github.com/home-lang/home/issues/416), adds the exact
`instanceof` substring to the existing one-pass source marker automaton.
Member-access checking skips its specialized fallthrough-join analysis only
when attached source bytes cannot contain that operator spelling. Sources that
contain it—including conservative comment and string matches—retain the full
flow, declared-annotation, intersection, and class-union checks.

The isolated A/B uses the same unchanged 16,384-family predicate stress project,
which contains no `instanceof` substring. The published HIR-index binary
(SHA-256 `faccb14ac520cd8a37d14246635089d36345ddf3c6d40d8630c59fcf5a73849e`)
is the baseline; the marker candidate has SHA-256
`842310b6c24e1e788c33d756bbff0e7df0b0bc60c261d4dcb8552f8c09ccb2cd`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round and retain all 40 finite samples.

| 16,384 predicate-family Home A/B | HIR-index baseline | `instanceof` guard | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Same project and settings | 2738.5 ± 31.3 ms | **2704.2 ± 38.5 ms** | **1.0127×** | **15/20 pairs** |

The mean paired reduction is 34.3 ms with a 95% paired t confidence interval of
15.0–53.6 ms; the exact two-sided sign-test result is `p = 0.0414`. In a fresh
1 ms sampling profile, the baseline enters
`identifierHasInstanceofFallthroughJoin` and descends through visible
annotation lowering, while the candidate remains at the marker guard and that
downstream stack disappears.

The independent 30-round confirmation is `20260831T005513Z`: TS 6.0.3 takes
1048.1 ± 15.7 ms, native TS 7.0.2 takes 365.1 ± 8.1 ms, and Home takes
**318.1 ± 4.6 ms**, a **1.15×** lead with 30/30 paired wins. The complete
20-workload result is `20260831T005639Z`, reported in the
[current snapshot](#current-snapshot): Home has the lower mean on 20/20 rows
and the lower individual time in 598/600 rounds. Both official runs retain
every sample and verify unchanged compiler provenance before admission and
after measurement.

### Tiny annotated-scope index checkpoint

Commit `96d05423e`, tracked by
[#416](https://github.com/home-lang/home/issues/416), keeps one- and
two-statement containers on the checker’s existing direct lexical scan instead
of allocating entries in both the annotated-declaration index and the set that
records indexed containers. The scan is bounded by two statements. Containers with three or
more statements retain the indexed path, including virtual-source-section keys,
and all callers retain their existing direct fallback. A focused regression
test verifies both the TS2322 result of an annotated local read and that its
two-statement function body does not build the index.

The isolated Home A/B uses the unchanged 16,384-family predicate stress project
and identical `--noEmit -p` arguments. The published `instanceof`-guard binary
(SHA-256 `842310b6c24e1e788c33d756bbff0e7df0b0bc60c261d4dcb8552f8c09ccb2cd`)
is the baseline; the measured candidate has SHA-256
`1b401eb95d51702a1a3467c80aede41dfe4107defb690c34f2420194cc2f4fdf`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round. All 40 finite samples are retained in
`tiny-visible-index-ab.kxWhRg`; none is filtered.

| 16,384 predicate-family Home A/B | Indexed tiny scopes | Bounded direct scan | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Same project and settings | 2699.9 ± 54.0 ms | **2651.6 ± 42.2 ms** | **1.0182×** | **16/20 pairs** |

The mean paired reduction is 48.3 ms with a 95% paired t confidence interval of
23.5–73.1 ms; the exact two-sided sign-test result is `p = 0.0118`. The focused
ReleaseFast test and complete ReleaseFast checker suite pass. The final
published Home binary, including that test, has SHA-256
`09fa07634b31ba0eb0a8671bf8c1e1fe85c69a22b7581f693f821703e10a8d6d`.

The independent 30-round confirmation is `20260831T012734Z`: TS 6.0.3 takes
1053.2 ± 18.7 ms, native TS 7.0.2 takes 365.7 ± 7.8 ms, and Home takes
**314.6 ± 4.8 ms**, a **1.16×** lead with 30/30 paired wins. The complete
20-workload result is `20260831T012857Z`, reported in the
[current snapshot](#current-snapshot): Home has the lower mean on 20/20 rows
and the lower individual time in 599/600 rounds. Both official runs retain
every sample and verify unchanged compiler provenance before admission and
after measurement.

### Prepared source-marker reuse checkpoint

Commit `1ae4ecfa6`, tracked by
[#416](https://github.com/home-lang/home/issues/416), computes the exact
one-pass source-marker index once during driver preparation and passes that
same index into the checker. Driver probes for source directives, triple-slash
references, and virtual filenames use conservative marker-presence gates;
sources containing the relevant sentinel retain the original parsing and
diagnostic paths. Compiler-option type references remain unconditional because
they can originate outside source text.

The isolated Home A/B uses the unchanged 16,384-family predicate stress project
and identical `--noEmit -p` arguments. The published tiny-scope binary
(SHA-256 `09fa07634b31ba0eb0a8671bf8c1e1fe85c69a22b7581f693f821703e10a8d6d`)
is the baseline; the marker-reuse candidate has SHA-256
`161e0142518e25a29cc2f60cff18364a2dbcff0719b89a9fec795dba9a195bfa`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round. All 40 finite samples are retained in
`source-marker-reuse-ab.OFleQk`; none is filtered.

| 16,384 predicate-family Home A/B | Repeated scans | Prepared marker reuse | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Same project and settings | 2666.8 ± 35.7 ms | **2596.0 ± 34.1 ms** | **1.0273×** | **20/20 pairs** |

The mean paired reduction is 70.8 ms with a 95% paired t confidence interval of
57.2–84.4 ms; the exact two-sided sign-test result is `p = 0.0000019`.
The focused ReleaseFast driver suite, supplied-marker checker regression,
Pickier, formatting, and diff checks pass. The unchanged benchmark project
also produces byte-identical stdout, stderr, and exit status with both Home
binaries.

The independent 30-round confirmation is `20260831T020935Z`: TS 6.0.3 takes
1051.0 ± 22.2 ms, native TS 7.0.2 takes 367.2 ± 6.5 ms, and Home takes
**305.2 ± 3.7 ms**, a **1.20×** lead with 30/30 paired wins. The complete
20-workload result is `20260831T021055Z`, reported in the
[current snapshot](#current-snapshot): Home has the lower mean on 20/20 rows
and the lower individual time in 600/600 rounds. Both official runs retain
every sample and verify unchanged compiler provenance before admission and
after measurement.

### Exact import-equals presence checkpoint

Commit `3454bbaa1`, tracked by
[#416](https://github.com/home-lang/home/issues/416), replaces a repeated
import-equals negative search with one cached exact HIR fact. The existing
source marker conservatively admits any file containing both `import` and `=`.
That includes ordinary named imports followed by unrelated assignments. Such a
file previously rescanned enclosing and root statement lists for every type
reference even though no `import local = Qualified.Name` or
`import local = require(...)` declaration could be found. A real import-equals
declaration still uses the original resolution and diagnostic paths unchanged;
HIR-only checker setups also retain the unfiltered path.

The isolated Home A/B uses the benchmark suite's unchanged recursive-generic
generator at 4,096 families and identical `--noEmit -p` arguments. This scaled
diagnostic corpus exposes the asymptotic repeated scan; it does not replace or
alter the standard 256-family competitor workload. Both binaries exit zero
with byte-identical empty stdout and stderr. The published prepared-marker
binary (SHA-256
`161e0142518e25a29cc2f60cff18364a2dbcff0719b89a9fec795dba9a195bfa`)
is the baseline; the exact final candidate has SHA-256
`6182abe599c8ee69a16161f061010ea7fc0232928748a887201321c9048491f3`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round. All 40 finite samples are retained in
`import-equals-exact-final-ab.4096`; none is filtered.

| 4,096 recursive-family Home A/B | Repeated statement scans | Cached exact HIR fact | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Same generated project and settings | 2063.9 ± 199.4 ms | **1205.9 ± 115.5 ms** | **1.7115×** | **20/20 pairs** |

The mean paired reduction is 858.0 ms with a 95% paired t confidence interval
of 774.6–941.3 ms; the exact two-sided sign-test result is `p = 0.0000019`.
The focused exact-fact test, the existing ReleaseFast import-equals test group,
the ReleaseFast production build, scoped Pickier lint, formatting, and diff
checks pass.

The independent 30-round standard-workload confirmation is
`20260831T030019Z`: TS 6.0.3 takes 175.6 ± 51.9 ms, native TS 7.0.2 takes
81.5 ± 24.3 ms, and Home takes **17.1 ± 2.3 ms**, a **4.76×** lead with
30/30 paired wins. The complete 20-workload result is `20260831T030052Z`,
reported in the [current snapshot](#current-snapshot): Home has the lower mean
on 20/20 rows and the lower individual time in 598/600 rounds. Both official
runs retain every sample and verify unchanged compiler provenance before
admission and after measurement.

### JSDoc global duplicate-name index checkpoint

Commit `800fff78b`, tracked by
[#416](https://github.com/home-lang/home/issues/416), replaces an all-pairs
scan in checked-JavaScript global duplicate diagnostics with source-ordered
same-name chains. The previous pass compared every JSDoc typedef and top-level
value with every later entry, then rejected almost every pair because the names
differed. The index links only equal names while the outer source-order walk is
unchanged, so every semantically relevant pair and its diagnostic order remain
the same.

The isolated Home A/B uses the benchmark suite's unchanged CheckJS/JSDoc
generator at 2,048 families and identical `--noEmit -p` arguments. This scaled
diagnostic corpus exposes the asymptotic duplicate scan; it does not replace or
alter the standard 128-family competitor workload. Both binaries exit zero
with byte-identical empty stdout and stderr. A separate invalid multi-file
fixture also produces byte-identical diagnostics and ordering. The published
exact-import binary (SHA-256
`6182abe599c8ee69a16161f061010ea7fc0232928748a887201321c9048491f3`)
is the baseline; the exact final candidate has SHA-256
`b02ecda7944783f0437b8c205177fb66b4b09aa6e9ddaf5d331161114626a633`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round. All 40 finite samples are retained in
`jsdoc-same-name-chain-final-ab.2048`; none is filtered.

| 2,048 CheckJS-family Home A/B | All-pairs name scan | Source-ordered same-name chains | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Same generated project and settings | 1857.4 ± 94.4 ms | **1793.6 ± 48.8 ms** | **1.0356×** | **17/20 pairs** |

The mean paired reduction is 63.9 ms with a 95% paired t confidence interval
of 24.1–103.7 ms; the exact two-sided sign-test result is `p = 0.0026`.
Independent process CPU time is 3.25% lower with the same 17/20 direction and
a 26.7–88.1 ms paired 95% interval. The focused diagnostic-order regression,
broader ReleaseFast `JSDoc typedef` checker subset, ReleaseFast production
build, scoped Pickier lint, formatting, and diff checks pass.

The independent 30-round standard-workload confirmation is
`20260831T040831Z`: TS 6.0.3 takes 245.1 ± 92.0 ms, native TS 7.0.2 takes
59.7 ± 3.1 ms, and Home takes **40.7 ± 9.4 ms**, a **1.47×** lead with
29/30 paired wins. The complete 20-workload result is `20260831T040903Z`,
reported in the [current snapshot](#current-snapshot): Home has the lower mean
on 20/20 rows and the lower individual time in 600/600 rounds. Both official
runs retain every sample and verify unchanged compiler provenance before
admission and after measurement.

### ASCII identifier scanner checkpoint

Commit `12e4f73ef`, tracked by
[#416](https://github.com/home-lang/home/issues/416), changes the identifier
scanner's dispatch order without changing its accepted syntax. The previous
loop probed both UTF-8 whitespace tables for every byte before testing whether
an ordinary ASCII letter or digit continues the identifier. The new path tests
ASCII continuation first. Backslash escapes still use the complete escape
path, and non-ASCII bytes still run both Unicode whitespace and line-terminator
checks. A focused regression verifies that U+00A0 and U+2028 terminate an
identifier and that U+2028 preserves the following token's newline flag.

The exact-final Home A/B uses the suite's unchanged type-predicate generator
at 32,768 families with identical `--noEmit -p` arguments. This is a scaled
diagnostic corpus for the scanner hotspot, not a replacement for the standard
2,048-family competitor row. Both binaries exit zero with byte-identical empty
stdout and stderr. The published JSDoc-index binary (SHA-256
`b02ecda7944783f0437b8c205177fb66b4b09aa6e9ddaf5d331161114626a633`)
is the baseline; the committed candidate has SHA-256
`aae87472b82685d59b37aa53218173120f8e6df190a473ca04477cf3b46637d6`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round. All 40 finite samples remain in
`ascii-identifier-fast-path-final-ab.32768`; none is filtered.

| 32,768 predicate-family Home A/B | UTF-8 probes before ASCII | ASCII continuation first | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Process CPU | 7353.4 ± 112.6 ms | **7129.1 ± 108.2 ms** | **1.0315×** | **20/20 pairs** |
| Wall clock | 8126.3 ± 277.9 ms | **8010.6 ± 689.5 ms** | **1.0145×** | **17/20 pairs** |

The CPU paired reduction is 224.3 ms with a 95% paired t confidence interval
of 178.9–269.7 ms; its exact two-sided sign-test result is `p = 0.0000019`.
Wall clock retains two early candidate machine-stall outliers, so its paired
t interval crosses zero (-125.4–357.0 ms) even though the direction is lower
in 17/20 pairs (`p = 0.0026` by the exact two-sided sign test). An independent
pre-test-layout build of the same production scanner logic measured a 1.0418×
wall reduction with a positive 100.7–326.8 ms paired interval. The shorter
8,192-family exact-final confirmation was directionally lower but inconclusive
under contemporaneous host variance (13/20 wall and CPU wins); its samples are
retained in `ascii-identifier-fast-path-final-ab.8192` rather than discarded.
The ReleaseFast lexer suite, Unicode regression, ReleaseFast production build,
formatting, and diff checks pass.

The exact committed-binary 30-round confirmation is `20260831T050122Z`: TS
6.0.3 takes 1017.3 ± 46.6 ms, native TS 7.0.2 takes 351.6 ± 8.1 ms, and Home
takes **288.4 ± 5.7 ms**, a **1.22×** lead. The complete 20-workload result is
`20260831T050307Z`, reported in the [current snapshot](#current-snapshot): Home
has the lower mean on 20/20 rows and the lower individual time in 600/600
rounds. Both official runs retain every sample and verify candidate SHA-256
`aae87472b82685d59b37aa53218173120f8e6df190a473ca04477cf3b46637d6`
before admission and after measurement.

### Builtin object name gate checkpoint

Commit `43e1f1ea8`, tracked by
[#416](https://github.com/home-lang/home/issues/416), adds an exact name gate
before builtin object-type lowering. Previously, every failed user-defined
type name traversed the long chain of builtin recipes and string comparisons.
The static index contains all and only the 44 names recognized by those
existing specialized and fallback paths. A matching name still runs its
original recipe unchanged; a nonmatching name now returns before the chain.

The exact-final Home A/B uses the suite's unchanged type-predicate generator
at 32,768 families with identical `--noEmit -p` arguments. Both binaries exit
zero with byte-identical empty stdout and stderr. The committed ASCII-scanner
binary (SHA-256
`aae87472b82685d59b37aa53218173120f8e6df190a473ca04477cf3b46637d6`)
is the baseline; the builtin-gate candidate has SHA-256
`58b48a6b39d76c7ffa6cf3343490bd7da423692135076f3cbee6da8b54aa8206`.
After three alternating warmup pairs, 20 measured pairs reverse process order
each round. All 40 finite samples remain in
`builtin-object-name-gate-final-ab.32768`; none is filtered.

| 32,768 predicate-family Home A/B | Recipe chain for every name | Exact 44-name gate | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| Wall clock | 4981.9 ± 172.9 ms | **4890.1 ± 149.9 ms** | **1.0188×** | **17/20 pairs** |
| Process CPU | 4960.5 ± 157.6 ms | **4866.9 ± 135.7 ms** | **1.0192×** | **16/20 pairs** |

The wall-clock mean paired reduction is 91.9 ms with a 95% paired t
confidence interval of 30.2–153.6 ms; its exact two-sided sign-test result is
`p = 0.0025768`. Process CPU time is lower by a paired mean of 93.6 ms with a
39.2–148.0 ms interval and `p = 0.0118179`. An independent pre-test-layout
build of the same production logic also measured lower wall and CPU means:
1.0207× and 1.0202× respectively, each with 19/20 lower candidate pairs and
positive paired confidence intervals. The focused completeness regression
resolves all 44 builtin recipes and rejects prefix and suffix lookalikes. A
mechanical audit reports 44 gated and 44 recognized names with no missing or
extra entries; the broader ReleaseFast checker builtin subset, ReleaseFast
production build, formatting, and diff checks pass.

The exact committed-binary 30-round confirmation is `20260831T053315Z`: TS
6.0.3 takes 999.6 ± 27.0 ms, native TS 7.0.2 takes 349.9 ± 11.5 ms, and Home
takes **280.7 ± 6.7 ms**, a **1.25×** lead. The complete 20-workload result is
`20260831T053521Z`, reported in the [current snapshot](#current-snapshot): Home
has the lower mean on 20/20 rows and the lower individual time in 600/600
rounds. Both official runs retain every sample and verify candidate SHA-256
`58b48a6b39d76c7ffa6cf3343490bd7da423692135076f3cbee6da8b54aa8206`
before admission and after measurement.

### Prehashed string interner checkpoint

Commit `94a5b3589`, tracked by
[#416](https://github.com/home-lang/home/issues/416), removes repeated hashing
from the shared string interner. Previously, `intern` computed Wyhash to choose
one of 64 shards and the shard's string map recomputed the same hash for its
optimistic read, exclusive-lock double-check, and insertion. `lookup` likewise
hashed for both shard selection and the map probe. The new adapted map key
carries the original Wyhash through those operations. The identical low bits
still select the shard; byte equality, locks, stable IDs, allocation ordering,
and owned key storage are unchanged.

The exact Home A/B uses the suite's unchanged predicate generator and identical
`--noEmit -p` arguments. Both binaries exit zero with byte-identical empty
stdout and stderr at both scales. The builtin-name-gate binary (SHA-256
`58b48a6b39d76c7ffa6cf3343490bd7da423692135076f3cbee6da8b54aa8206`)
is the baseline; the committed prehash candidate has SHA-256
`977e3cc7ab65ff1c0e1f7f382aebd8258e45baea5ed1fb2b03892b44c11fa9f0`.
Each confirmatory run uses three alternating warmup pairs and 20 measured pairs
whose process order reverses every round. All 80 finite samples remain in the
two raw directories; none is filtered or pooled across scales.

| Home A/B | Repeated Wyhash | Reused exact Wyhash | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| 32,768 families, process CPU | 4730.5 ± 34.8 ms | **4706.2 ± 45.5 ms** | **1.0052×** | **13/20 pairs** |
| 32,768 families, wall clock | 4738.5 ± 35.7 ms | **4718.4 ± 48.6 ms** | **1.0043×** | **12/20 pairs** |
| 65,536 families, process CPU | 9824.1 ± 84.5 ms | **9764.4 ± 73.6 ms** | **1.0061×** | **15/20 pairs** |
| 65,536 families, wall clock | 9865.2 ± 95.2 ms | **9806.4 ± 86.4 ms** | **1.0060×** | **14/20 pairs** |

At 32,768 families, the CPU paired reduction is 24.3 ms with a 95% paired t
confidence interval of 0.5–48.2 ms; its exact two-sided sign-test result is
`p = 0.2632`. The wall interval is -5.6–45.8 ms. At 65,536 families, CPU is
lower by a paired mean of 59.8 ms with a 4.7–114.9 ms interval and 15/20 lower
candidate pairs (`p = 0.0414` by the exact two-sided sign test). Its wall mean
is lower by 58.8 ms, with a -2.3–119.9 ms interval. A separate ten-pair
32,768-family screen, retained but not pooled, measured 1.0108× lower wall and
CPU means with 9/10 lower candidate pairs and positive paired intervals.

A fresh 1 ms sampling profile confirms the intended mechanism: the duplicated
string-map `get` leaf disappears, Wyhash leaf samples fall from 34 to 16, and
byte-equality leaves fall from 334 to 291. These profile counts explain the
change and are not timing claims. Validation passes the ReleaseFast interner
suite (shared ownership, concurrency, deterministic sharding, and allocation
failure), the ReleaseFast type-predicate checker subset, the ReleaseFast
production build, formatting, and diff checks.

Two adjacent ideas were measured and fully reverted. Adding `@target` to the
one-pass marker automaton was effectively flat over 20 pairs: wall measured
4849.1 ± 202.1 ms versus 4848.9 ± 147.6 ms (8/20 lower candidate pairs, paired
interval -74.2–74.5 ms), while CPU was slightly higher. A compile-time-derived
builtin terminal-byte prefilter was also flat in its ten-pair screen: wall
measured 5233.9 ± 234.5 ms versus 5225.5 ± 269.3 ms (5/10 pairs, interval
-108.2–125.1 ms), with the same 5/10 direction for CPU. Neither probe appears
in the committed compiler or contributes to the accepted measurements.

The exact committed-binary 30-round standard-workload confirmation is
`20260831T063321Z`: TS 6.0.3 takes 980.1 ± 15.5 ms, native TS 7.0.2 takes
342.9 ± 7.2 ms, and Home takes **274.2 ± 3.7 ms**, a **1.25×** lead. The
complete 20-workload result is `20260831T063443Z`, reported in the
[current snapshot](#current-snapshot): Home has the lower mean on 20/20 rows
and the lower individual time in 600/600 rounds. Both official runs retain
every sample and verify candidate SHA-256
`977e3cc7ab65ff1c0e1f7f382aebd8258e45baea5ed1fb2b03892b44c11fa9f0`
before admission and after measurement.

### Prehashed type interner checkpoint

Commit `79b6b6360`, tracked by
[#416](https://github.com/home-lang/home/issues/416), applies the same exact-hash
reuse to structural type keys. Previously, each `TypeKey` was hashed once to
choose one of 64 shards and again inside every optimistic read, exclusive-lock
double-check, and insertion. The adapted probe now carries that original hash
through scalar keys, owned tuple and instantiation keys, template literals,
and canonical union/intersection slices. Structural `TypeKey.eql` remains the
collision check; shard selection, owned key storage, locks, stable TypeIds, and
pool contents are unchanged. Shard-table capacity is reserved before pool
publication, so inserting the already-published type requires no allocation.

The exact Home A/B uses the unchanged predicate generator and identical
`--noEmit -p` commands. Both binaries exit zero with byte-identical empty
stdout and stderr at 32,768 and 65,536 families. The prehashed-string binary
(SHA-256
`977e3cc7ab65ff1c0e1f7f382aebd8258e45baea5ed1fb2b03892b44c11fa9f0`)
is the baseline; the committed type-prehash candidate has SHA-256
`e313cd557ae66e601792c947eff07a06c8a19b3421c7537623be3d2f9f85899b`.
Each confirmatory run uses three alternating warmup pairs and 20 measured pairs
whose process order reverses every round. All 80 finite samples remain under
`type-interner-prehash.FxAMAs/final-ab.{32768,65536}`; none is filtered or
pooled across scales.

| Home A/B | Repeated TypeKey hash | Reused exact hash | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| 32,768 families, process CPU | 4681.0 ± 27.3 ms | **4639.9 ± 32.7 ms** | **1.0089×** | **16/20 pairs** |
| 32,768 families, wall clock | 4689.7 ± 29.9 ms | **4648.9 ± 33.4 ms** | **1.0088×** | **16/20 pairs** |
| 65,536 families, process CPU | 9664.1 ± 93.1 ms | **9596.5 ± 72.6 ms** | **1.0070×** | **16/20 pairs** |
| 65,536 families, wall clock | 9679.6 ± 100.9 ms | **9611.4 ± 77.8 ms** | **1.0071×** | **16/20 pairs** |

At 32,768 families, the paired CPU reduction is 41.1 ms with a 95% paired t
confidence interval of 19.9–62.3 ms; wall clock is lower by 40.8 ms with a
19.8–61.8 ms interval. At 65,536 families, CPU is lower by 67.6 ms with a
21.3–114.0 ms interval; wall clock is lower by 68.2 ms with a 16.3–120.1 ms
interval. Every row has 16/20 lower candidate pairs and an exact two-sided
sign-test result of `p = 0.0118`. A separate unpooled ten-pair screen at 32,768
families measured 1.0110× lower wall and 1.0100× lower CPU means, with positive
paired intervals.

A fresh 1 ms sampling profile confirms the intended mechanism: the previous
58-sample `TypeKey` map `getIndex` leaf disappears; ordinary map growth remains.
This profile observation explains the change and is not a timing claim.
Validation passes the ReleaseFast type-interner groups, including concurrent
deduplication and allocation-failure coverage, the ReleaseFast type-predicate
checker subset, the ReleaseFast production build, exact output checks at both
scales, formatting, and diff checks.

One adjacent cleanup was measured and fully reverted. Removing a second
top-level annotated-variable lookup produced a positive ten-pair screen at
32,768 families (1.0108× lower wall and 1.0106× lower CPU means, 10/10 lower
candidate pairs, positive paired intervals), but the independent confirmations
did not clear the paired-mean acceptance bar. At 32,768 families, wall measured
4638.4 ± 41.2 ms versus 4611.3 ± 48.4 ms (1.0059×, 15/20 pairs, paired interval
-7.0–61.1 ms); CPU measured 4631.7 ± 39.5 ms versus 4603.9 ± 45.9 ms (1.0060×,
15/20 pairs, interval -5.0–60.6 ms). At 65,536 families, wall measured
9632.2 ± 79.7 ms versus 9582.9 ± 75.1 ms (1.0052×, 13/20 pairs, interval
-6.9–105.6 ms); CPU measured 9619.1 ± 72.4 ms versus 9568.6 ± 69.9 ms
(1.0053×, 14/20 pairs, interval -1.5–102.5 ms). Both binaries preserved exact
output at both scales, and the focused annotation suite passed, but positive
means with intervals crossing zero are not a retained performance result. All
raw rounds remain under `annotated-root-lookup.3jRs1g`; the probe is absent
from the compiler.

The exact committed-binary 30-round standard-workload confirmation is
`20260831T071216Z`: TS 6.0.3 takes 977.9 ± 10.1 ms, native TS 7.0.2 takes
343.3 ± 7.9 ms, and Home takes **274.5 ± 8.4 ms**, a **1.25×** lead. The
complete 20-workload result is `20260831T071413Z`, reported in the
[current snapshot](#current-snapshot): Home has the lower mean on 20/20 rows
and the lower individual time in 600/600 rounds. Both official runs retain
every sample and verify candidate SHA-256
`e313cd557ae66e601792c947eff07a06c8a19b3421c7537623be3d2f9f85899b`
before admission and after measurement.

### Hot string-interner cache checkpoint

Commit `7f02a93dd`, tracked by
[#416](https://github.com/home-lang/home/issues/416), adds a 64-entry
direct-mapped lookup hint to each of the 64 string-interner shards. The cache
occupies 32 KiB in total and stores only a 32-bit hash fingerprint plus a local
index. Every possible hit is checked against the canonical owned bytes while
holding the existing shard lock. Slot and fingerprint collisions therefore
fall through to the canonical prehashed map; string identity, stable IDs,
owned storage, sharding, and locking semantics are unchanged. Map hits refresh
the hint, and new entries become visible only after their canonical string and
table entry have been published.

The exact Home A/B uses the unchanged predicate generator and identical
`--noEmit -p` commands. Both binaries exit zero with byte-identical empty
stdout and stderr at 32,768 and 65,536 families. The type-prehash binary
(SHA-256
`e313cd557ae66e601792c947eff07a06c8a19b3421c7537623be3d2f9f85899b`)
is the baseline; the committed hot-cache candidate has SHA-256
`be09b86b82af35703a8f812dad92014ddf5250e0c9e721c2078bc82a791ac35d`.
Each confirmatory run uses three alternating warmup pairs and 20 measured pairs
whose process order reverses every round. All 80 finite samples remain under
`string-interner-hot-cache.T0d2PQ/final-ab.{32768,65536}`; none is filtered or
pooled across scales.

| Home A/B | Canonical map only | Hot cache + canonical fallback | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| 32,768 families, process CPU | 4706.6 ± 50.2 ms | **4575.0 ± 47.7 ms** | **1.0288×** | **20/20 pairs** |
| 32,768 families, wall clock | 4715.4 ± 52.3 ms | **4583.7 ± 51.2 ms** | **1.0287×** | **19/20 pairs** |
| 65,536 families, process CPU | 9720.4 ± 90.0 ms | **9465.3 ± 111.8 ms** | **1.0269×** | **19/20 pairs** |
| 65,536 families, wall clock | 9776.2 ± 93.6 ms | **9527.9 ± 122.3 ms** | **1.0261×** | **18/20 pairs** |

At 32,768 families, the paired CPU reduction is 131.7 ms with a 95% paired t
confidence interval of 98.5–164.9 ms; wall clock is lower by 131.7 ms with a
97.1–166.3 ms interval. At 65,536 families, CPU is lower by 255.1 ms with a
176.9–333.2 ms interval; wall clock is lower by 248.2 ms with a 162.2–334.3 ms
interval. The exact two-sided sign-test results range from `p = 0.0000019` to
`p = 0.0004025`. A separate unpooled ten-pair screen at 32,768 families
measured 1.0242× lower wall and 1.0247× lower CPU means, with 10/10 lower
candidate pairs and positive paired intervals.

A fresh 1 ms sampling profile confirms the intended mechanism:
`string_interner.Interner.internAt` leaf samples fall from 220 to 92, while
byte-equality leaf samples remain essentially flat at 207 versus 205. This is
consistent with avoiding canonical map probes while retaining full-byte
verification; the profile counts are explanatory, not timing claims.
Validation passes the complete ReleaseFast string-interner suite, the
ReleaseFast type-predicate checker subset, the ReleaseFast production build,
exact output checks at both scales, formatting, and diff checks.

One follow-on memoization was measured and fully reverted. Caching
`containsFreeTypeParameter` results in a checker-local hash map preserved exact
output and passed the focused ReleaseFast predicate suite, but its ten-pair
32,768-family screen was slightly slower. Wall clock measured 4497.1 ± 37.4 ms
for the accepted binary versus 4517.5 ± 79.8 ms for the candidate (0.9955×,
4/10 lower candidate pairs, paired interval -88.2–47.5 ms). Process CPU
measured 4486.4 ± 35.9 ms versus 4501.7 ± 64.9 ms (0.9966×, 3/10 pairs,
interval -71.1–40.4 ms). The map lookup and maintenance cost did not justify
the avoided graph walks. All raw rounds remain under
`free-type-param-cache.Npjpjh/preliminary-ab.32768`; the memoization is absent
from the compiler.

The exact committed-binary 30-round focused confirmation is
`20260831T081314Z`: TS 6.0.3 takes 985.8 ± 14.9 ms, native TS 7.0.2 takes
342.1 ± 5.5 ms, and Home takes **257.3 ± 3.1 ms**, a **1.33×** lead. The
complete 20-workload result is `20260831T081507Z`, reported in the
[current snapshot](#current-snapshot): Home has the lower mean on 20/20 rows
and the lower individual time in 599/600 rounds. Both official runs retain
every sample and verify the candidate SHA-256 shown above before admission and
after measurement.

### ASCII trivia-boundary checkpoint

Commit `efdf8b574`, tracked by
[#416](https://github.com/home-lang/home/issues/416), removes unnecessary
Unicode-whitespace probes at ordinary ASCII token boundaries. Every supported
non-ASCII whitespace and line terminator begins with a high byte, so
`skipTrivia` can return immediately when its otherwise-unrecognized current
byte is ASCII. The existing UTF-8 recognition, tokenization, diagnostics, and
source traversal are unchanged.

The exact Home A/B again uses the unchanged predicate generator and identical
`--noEmit -p` commands. Both binaries exit zero with byte-identical empty
stdout and stderr at 32,768 and 65,536 families. The hot string-cache binary
(SHA-256
`be09b86b82af35703a8f812dad92014ddf5250e0c9e721c2078bc82a791ac35d`)
is the baseline; the committed ASCII-boundary candidate has SHA-256
`150c2206d8d38990a2d0054d03c8939357960d5a26c0e6c0b9ca560d7fc8581b`.
Each confirmatory run uses three alternating warmup pairs and 20 measured pairs
whose process order reverses every round. The reported rows are independent
and are not pooled across scales.

| Home A/B | Unicode probe at every boundary | ASCII boundary fast path | Baseline / candidate | Lower candidate time |
|---|---:|---:|---:|---:|
| 32,768 families, process CPU | 4466.5 ± 34.6 ms | **4426.8 ± 42.4 ms** | **1.0090×** | **18/20 pairs** |
| 32,768 families, wall clock | 4477.4 ± 35.9 ms | **4435.1 ± 44.3 ms** | **1.0096×** | **18/20 pairs** |
| 65,536 families, process CPU | 9200.4 ± 53.6 ms | **9064.6 ± 51.2 ms** | **1.0150×** | **20/20 pairs** |
| 65,536 families, wall clock | 9212.7 ± 55.0 ms | **9079.2 ± 52.4 ms** | **1.0147×** | **20/20 pairs** |

At 32,768 families, the paired CPU reduction is 39.7 ms with a 95% paired t
confidence interval of 14.3–65.1 ms; wall clock is lower by 42.4 ms with a
15.9–68.8 ms interval. At 65,536 families, CPU is lower by 135.8 ms with a
104.2–167.4 ms interval; wall clock is lower by 133.5 ms with a 101.0–166.1 ms
interval. Exact two-sided sign-test results are `p = 0.0004025` at 32,768 and
`p = 0.0000019` at 65,536. A separate unpooled ten-pair screen at 32,768
families measured 1.0091× lower wall and 1.0094× lower CPU means, with positive
paired intervals.

The first 65,536-family confirmation is also retained without filtering. It
contains an 11.51-second baseline wall outlier: wall measured
9357.5 ± 511.1 ms versus 9133.1 ± 49.3 ms (1.0246×, 19/20 pairs, paired
interval -5.9–454.6 ms), while CPU measured 9300.7 ± 327.1 ms versus
9118.4 ± 45.5 ms (1.0200×, 19/20 pairs, interval 31.7–333.0 ms). The
independent repeat above reversed the starting process order and supplies the
clean positive wall and CPU intervals; the noisy run remains part of the
record rather than being substituted or trimmed.

A fresh 1 ms sampling profile on the doubled workload records only three total
`unicodeWhitespaceLengthAt` stack occurrences, versus 35 leaf samples in the
previous accepted 32,768-family profile. The counts confirm that ordinary
ASCII boundaries no longer enter the Unicode probe; they are explanatory, not
timing claims. Validation passes the complete ReleaseFast lexer suite,
ReleaseFast parser suite, ReleaseFast type-predicate checker subset, the
ReleaseFast production build, exact output checks at both scales, formatting,
and diff checks. All A/B rounds and the profile remain under
`ascii-trivia-fast-path.IbEFgd/`.

One adjacent keyword-lookup replacement was measured and fully reverted.
Zig's compile-time `StaticStringMap` preserved all keyword and lexer tests plus
exact compiler output, but its ten-pair 32,768-family screen was slightly
slower than the existing compile-time length buckets. Wall clock measured
4425.8 ± 44.9 ms for the accepted binary versus 4441.2 ± 40.6 ms for the
candidate (0.9965×, 6/10 lower candidate pairs, paired interval
-61.2–30.4 ms). Process CPU measured 4415.4 ± 43.2 ms versus
4432.3 ± 40.5 ms (0.9962×, 5/10 pairs, interval -61.0–27.1 ms). All raw
rounds remain under `static-keyword-map.7qVurl/preliminary-ab.32768`; the
static map is absent from the compiler. The existing lookup documentation now
correctly records that the largest length bucket contains 16 candidates.

A purpose-built collision-free keyword index was also measured and fully
reverted. A compile-time-verified 256-byte table used keyword length, the first
two bytes, and the final byte to select one candidate, followed by an exact
byte comparison. It preserved the complete keyword and lexer suite plus exact
compiler output, but its ten-pair 32,768-family screen did not justify the
runtime arithmetic and table load. Wall clock measured 4701.1 ± 166.1 ms for
the accepted binary versus 4749.8 ± 303.7 ms for the candidate (0.9897×,
5/10 lower candidate pairs, paired interval -229.5–132.1 ms). Process CPU
measured 4666.3 ± 148.6 ms versus 4700.7 ± 253.9 ms (0.9927×, 5/10 pairs,
interval -180.4–111.6 ms). The host was slower than the earlier static-map
screen, so only paired within-batch differences are interpreted. All raw
rounds remain under `perfect-keyword-index.YBAnkb/preliminary-ab.32768`; the
perfect index is absent from the compiler.

An exact source-marker gate for the legacy inline `@target` scan was measured
and fully reverted as well. The candidate used the already-computed exact
Aho–Corasick marker index to prove that `@target` was absent whenever a source
contained no `@`; sources containing `@` retained the original directive
parser. Both fixed binaries produced byte-identical output at 32,768 and
65,536 families. After three alternating warmup pairs, the ten-pair
32,768-family screen measured 5133.2 ± 503.0 ms for the accepted binary and
5178.6 ± 505.6 ms for the candidate in wall time (0.9912×, 5/10 lower
candidate pairs, paired interval -242.1–151.3 ms). Process CPU measured
5027.4 ± 401.3 ms versus 5020.1 ± 321.2 ms (1.0015×, 6/10 pairs, paired
interval -140.5–155.2 ms). The variable host makes the paired interval the
decision criterion, and neither metric justified the branch. Raw rounds remain
under `target-option-gate.shBw7j/preliminary-ab.32768`; the gate is absent from
the compiler.

Passing the already-indexed virtual-section fact into `Parser.init` was also
measured and fully reverted. This removed two exact full-source searches for
`@filename:` and `@Filename:` from the program driver while preserving the
fallback initializer for direct parser callers. ReleaseFast parser and driver
suites passed, and fixed binaries produced byte-identical output at both
scales. A ten-pair 32,768-family screen favored the candidate by 1.0178× wall
and 1.0153× process CPU, but both paired intervals crossed zero. An independent
20-pair repeat still showed lower candidate means (5076.6 ± 248.2 ms versus
4977.2 ± 235.4 ms wall; 4968.7 ± 187.6 ms versus 4895.9 ± 188.4 ms CPU),
yet its paired intervals remained -17.9–216.8 ms and -19.5–165.1 ms. The
decisive 65,536-family run did not reproduce the margin: wall measured
10054.8 ± 378.2 ms versus 10039.3 ± 372.8 ms (1.0015×, 13/20 pairs,
interval -120.8–151.7 ms), and CPU measured 9911.9 ± 309.1 ms versus
9908.9 ± 323.3 ms (1.0003×, 10/20 pairs, interval -107.2–113.3 ms). All raw
rounds remain under `parser-virtual-section-fact.BUr50C`; the API change is
absent from the compiler.

A declaration-diagnostic pass census was measured and fully reverted. The
candidate classified top-level HIR declaration kinds once, then skipped each
of eight specialized merge passes only when its required kinds were provably
absent. It passed the full ReleaseFast checker suite and produced byte-identical
output at both scales, but the added census merely offset the avoided empty
passes. The ten-pair 32,768-family screen measured 4762.9 ± 84.4 ms for the
accepted binary versus 4757.8 ± 128.0 ms for the candidate in wall time
(1.0011×, 6/10 lower candidate pairs, paired interval -107.5–117.8 ms).
Process CPU measured 4732.5 ± 60.6 ms versus 4725.7 ± 101.0 ms (1.0014×,
6/10 pairs, interval -81.3–94.9 ms). Raw rounds remain under
`declaration-pass-gates.4tu8mP/preliminary-ab.32768`; the census is absent from
the compiler.

The exact committed-binary 30-round focused confirmation is
`20260831T091833Z`: TS 6.0.3 takes 980.2 ± 14.7 ms, native TS 7.0.2 takes
345.0 ± 13.2 ms, and Home takes **256.2 ± 8.2 ms**, a **1.35×** lead. The
complete 20-workload result is `20260831T091953Z`, reported in the
[current snapshot](#current-snapshot): Home has the lower mean on 20/20 rows
and the lower individual time in 599/600 rounds. Both official runs retain
every sample and verify the candidate SHA-256 shown above before admission and
after measurement.

## Historical workload milestones

The comparisons below retain each recorded milestone and its snapshot ID;
they are not replacements for the latest unfiltered table above.

The `control_flow` workload was deliberately added before these optimizations.
Its five-run red baseline (`20260826T203831Z`) measured Home at
2,927.8 ± 159.6 ms versus native TypeScript 7 at 81.5 ± 21.8 ms. The unchanged
workload measured 41.6 ± 0.7 ms in snapshot `20260827T151143Z`: a 70.4×
Home improvement and a 1.34× win over the fastest competitor. The improvement
came from removing repeated general-purpose source and HIR scans; the corpus,
compiler options, validity gate, and measurement schedule were not weakened.

The `overload_resolution` workload was likewise frozen before its optimization.
Its five-run red baseline (`20260826T221712Z`) measured Home at
126.9 ± 0.9 ms versus native TypeScript 7 at 70.3 ± 1.1 ms. The unchanged
workload measured 36.2 ± 0.5 ms in snapshot `20260827T151143Z`: a 3.51×
Home improvement and a 1.69× win over the fastest competitor. The optimized
path only eliminates candidates whose fixed primitive literal parameter is
provably incompatible with the corresponding literal expression.

The `class_hierarchy` workload was also frozen before optimization. Its
five-run red baseline (`20260826T232221Z`) measured Home at 79.4 ± 2.8 ms
versus native TypeScript 7 at 59.6 ± 1.5 ms. The unchanged workload measured
34.8 ± 1.6 ms in snapshot `20260827T151143Z`: a 2.28× Home improvement
and a 1.48× win over the fastest competitor. The optimization caches successful
general-purpose heritage resolutions and removes source or HIR scans only when
conservative facts prove the searched construct cannot apply; the source,
compiler options, validity gate, and schedule are unchanged.

The `structural_objects` workload was frozen before optimization. Its five-run
red baseline (`20260826T234904Z`) measured Home at 160.9 ± 4.5 ms versus
native TypeScript 7 at 62.7 ± 2.7 ms. The unchanged workload measured
35.2 ± 1.5 ms in snapshot `20260827T151143Z`: a 4.57× Home improvement and
a 1.58× win over the fastest competitor. Profiling found that DOM library
availability was rescanning the complete source for every relevant annotation;
the result now uses the checker's existing per-source fact lifecycle. The
corpus, compiler options, validity gate, and measurement schedule were not
weakened.

The `interface_composition` workload was frozen before optimization. Its
five-run red baseline (`20260827T000848Z`) measured Home at 117.3 ± 3.0 ms
versus native TypeScript 7 at 65.3 ± 0.8 ms. The unchanged workload measured
47.1 ± 1.2 ms in snapshot `20260827T151143Z`: a 2.49× Home improvement
and a 1.29× win over the fastest competitor. The implementation replaces
repeated namespace, declaration-merge, annotation, and type-name searches with
validated indexes and conservative source facts. The generated source, compiler
options, silent-success validity gate, and interleaved schedule remain
unchanged.

The `variadic_tuples` workload was frozen before optimization. Its five-run red
baseline (`20260827T072451Z`) measured Home at 209.4 ± 4.8 ms versus native
TypeScript 7 at 100.7 ± 3.3 ms. The exact same generated project measured
48.5 ± 0.8 ms in snapshot `20260827T151143Z`: a 4.32× Home improvement and a
1.50× win over the fastest competitor. The general changes prune non-inferable
generic pairs, index lexical value declarations, retain the relation working
set, and skip syntax-inapplicable scans.
The corpus, compiler options, silent-success validity gate, and interleaved
schedule were not changed after the baseline was recorded.

The `checkjs_jsdoc` workload was accepted and frozen only after Home, `tsc`,
and `tsgo` all checked the same JavaScript project successfully and all three
rejected a preserved invalid variant with `TS2322`. The first semantically
valid Home implementation was impractically slow because it repeatedly found
the owning function and JSDoc declaration for each use; at 64 generated
families it took roughly 14 seconds and its growth made a 128-family timing
run unsuitable as a benchmark baseline. A direct development comparison after
the first general indexing pass still measured Home at 150.7 ± 17.5 ms versus
native TypeScript 7 at 111.4 ± 8.7 ms and `tsc` at 555.0 ± 74.8 ms. The
unchanged accepted workload measured 49.3 ± 1.0 ms in interleaved snapshot
`20260827T151143Z`, a 3.06× Home improvement from that intermediate result
and a 1.06× win over the fastest competitor. The implementation indexes named
JSDoc declarations and their owning functions, memoizes immutable physical
typedef and callback types, reuses binder and lexical indexes, and uses exact
source facts to avoid searches that cannot apply. Virtual sections and scoped
fallback resolution retain their complete semantic paths.

The `type_predicates` workload was frozen at SHA-256
`8b04ff5b9ae889c940facb652e5c925c7ff2aa6350058292208ca29020192350`
before optimization. Home, `tsc` 6.0.3, and native TypeScript 7.0.2 all accept
the same 13,312-line project silently, and all three reject a preserved variant
that assigns a narrowed string property to `number` with `TS2322`. Its
five-run red baseline (`20260827T133314Z`) measured Home at 132.3 ± 1.8 ms
versus native TypeScript 7 at 79.8 ± 1.4 ms. The unchanged workload measured
69.0 ± 4.9 ms in snapshot `20260827T151143Z`: a 1.92× Home improvement
and a 1.01× win over the fastest competitor. The general implementation uses
exact token-aware source facts, lexical declaration indexes, parameter-name
buckets, binder-backed root lookups, and successful named-shape caches; it does
not recognize the benchmark's generated names or family count.

The `null_safe_access` workload was frozen at 8,192 lines and 245,538 bytes,
with SHA-256
`22559101b63ff7129383baa604a006d33a37cd0ba4aa499a849ffd26894ff57c`.
All three compilers accept the same project silently and reject a preserved
invalid tuple string-to-number assignment with `TS2322`. Its five-run red
baseline (`20260827T152206Z`) measured Home at 1166.8 ± 11.0 ms versus native
TypeScript 7 at 62.1 ± 1.6 ms: an 18.79× loss. In the unchanged 30-run
snapshot `20260827T154256Z`, Home measures 51.1 ± 14.1 ms versus 71.3 ± 26.9
ms for native TypeScript 7, a 22.83× Home improvement and a 1.40× mean win.
Profiling found source-annotation recovery repeatedly searching unrelated
typed signatures for contextually typed, unannotated arrow parameters. The
general lexical/source guard removes only that impossible search. A scaled
1,024-family profiling copy dropped from 71.70 seconds to 0.32 seconds; the
accepted corpus, configuration, validity gate, and timing schedule stayed
unchanged. The complete checker gate passes 4,192 tests including the new
source-recovery regression.

The checked-JavaScript margin follow-up retained the losing snapshot
`20260827T154256Z` rather than filtering its slow sample. Profiling a
2,048-family same-shape copy showed that first-time JSDoc comment ownership
queries still scanned every HIR node. Commit `332e22826` builds a sorted,
nested function-span index and resolves those positions by binary search plus
the enclosing-span chain. Its regression compares indexed and original-scan
answers at every source position in nested function, arrow, and function
expression input, and checks source-state invalidation. The scaled profile
copy fell from 4.55 seconds to 2.31 seconds; the unchanged accepted 128-family
source (SHA-256
`898573fc0f2567653fef3edb3675d768f825abd80b83e708e7d57d29049c03ec`)
measures 40.1 ± 0.9 ms versus native TypeScript 7 at 51.7 ± 1.1 ms in snapshot
`20260827T155812Z`, a 1.29× mean win. All three compilers still accept the
valid project silently and reject the preserved string-to-number JSDoc variant
with `TS2322`; the complete checker gate passes 4,193 tests.

The `destructuring` workload was frozen at 4,032 lines and 122,226 bytes,
with SHA-256
`17049403e0a09a25e1f5ca78d730a7a683e78fd375681aaf1af92c460bbde673`.
All three compilers accept the source silently and pass the five automatic
negative controls described above. Its five-run baseline (`20260827T160641Z`)
measured Home at 97.6 ± 0.4 ms versus native TypeScript 7 at 45.3 ± 2.1 ms:
a 2.15× loss. The same baseline also recorded a type-predicate loss, Home
71.4 ± 8.5 ms versus native TypeScript 7 at 68.2 ± 0.4 ms; those results
remain part of the record.

Profiling a 1,024-family same-shape copy found that source-annotation recovery
repeated raw containment scans for each identifier use, including repeated
rejection of object properties that resemble typed parameters. Commit
`06baa9965` materializes each queried name's candidate ranges once and reuses
them, without changing which candidates are accepted. The regression compares
cached and original scan results at every declaration/use position pair in
nested, default-parameter, object-literal, incomplete, and string-containing
sources, and verifies invalidation when source facts change. The scaled
diagnostic run fell from 34.44 seconds to 2.74 seconds; this single-run profile
measurement is not a suite speedup claim. The complete checker gate passes
4,194 tests and the ReleaseFast build passes. The accepted corpus, compiler
configuration, and interleaved timing schedule are unchanged. In the complete
30-run snapshot `20260827T162037Z`, the accepted destructuring project measures
47.8 ± 14.0 ms for Home versus 63.4 ± 25.2 ms for native TypeScript 7: a
1.32× mean win, with the substantial variance explicitly retained.
This milestone is tracked in
[issue #453](https://github.com/home-lang/home/issues/453).

The type-predicate margin follow-up
([issue #455](https://github.com/home-lang/home/issues/455)) retains snapshot
`20260827T162037Z`: Home 78.1 ± 2.3 ms versus native TypeScript 7 at
82.3 ± 7.4 ms, only a 1.05× mean lead. A 2,048-family same-shape profiling
copy measured 1.23 seconds before this follow-up and exposed repeated failed
named-object-shape searches during narrowing. Commit `2de4f7670` caches
negative lookup results with the type-name table generation, separately for
each class-preference mode.
Inserting or rebinding a type name invalidates those misses, while re-registering
the same binding does not. The original shape comparison and successful
lookup behavior are unchanged. Regression coverage checks registration,
same-count rebinding, no-op updates, source reset, and class/non-class
preference separation. The accepted type-predicate source hash is unchanged;
the four automatic negative controls strengthen the gate without adding work
to the timed project. The complete checker gate passes 4,196 tests, the
ReleaseFast build passes, and all three compilers pass all 17 positive projects
plus the nine automatic predicate/destructuring negative controls.

The same scaled diagnostic copy then measured 0.99 seconds, with retired
instructions falling from 16.582 billion to 13.298 billion. These single-run
profiling observations are not the suite comparison. A short, preliminary
10-sample comparison remained noisy (Home 78.9 ± 19.7 ms versus native
TypeScript 7 at 80.3 ± 9.8 ms). Follow-up sampling still identifies first-time
shape searches and function-declaration scans as remaining general costs.

The complete 30-run snapshot `20260827T163618Z` records Home at 87.7 ± 13.5 ms
versus native TypeScript 7 at 93.4 ± 17.1 ms, a 1.07× mean lead. The timing
variance does not establish a robust margin, so issue #455 remains open for
those remaining costs. All 17 workloads have lower Home means in this snapshot;
all samples, including the high-variance null-safe-access row, are retained.

The next #455 follow-up targets repeated function-declaration searches, which
appear at the top of 133 of 495 sampled stacks in the post-cache profiling
trace. A per-container index now retains the first eligible function binding
by name, including exported declarations and variable-bound function/arrow
initializers. Caller scope walks and binder precedence are unchanged; empty
and singleton lists still use the constant-size scan. Indexes are published
only after construction succeeds, and allocation failure uses the original
scanner. Regressions compare indexed and scanned results across overloads,
nested namespaces and blocks, exported bindings, and missing/non-function
names; they also verify source reset and failure at both index allocation
stages. The accepted benchmark source and compiler options remain unchanged.
The full checker suite passes 4,198 tests; the ReleaseFast build, all 17
three-compiler positive gates, and all nine automatic negative controls pass.

Commit `983c2c532` implements the function index. Alternating the preserved
pre-index and new release binaries on the accepted 256-family source gives
72.19 ± 3.12 ms before versus 70.12 ± 3.42 ms after (30 samples per binary,
three warmups). The 2,048-family copy gives 1,056.42 ± 59.81 ms before versus
850.96 ± 23.82 ms after (five samples per binary, two warmups). These are
interleaved before/after development measurements, not competitor results.

That larger input also exposes a remaining scaling loss. A preliminary
five-run, three-warmup round-robin comparison gives Home 801.0 ± 22.4 ms,
native TypeScript 7 at 369.4 ± 15.4 ms, and JavaScript TypeScript 6 at
1,063.8 ± 43.0 ms: Home is 2.17× slower than the faster competitor. All three
compilers accept it silently and reject all four guard/assertion controls.
The workload is now included separately as `type_predicates_large`, with
106,496 lines, 3,032,376 bytes, and SHA-256
`9966d3e8933894a6a67f4f28c606765df0a7650f6cef429a758797151c2f6bca`.
It uses the same generator and configuration; the original 256-family source
is unchanged. [Issue #457](https://github.com/home-lang/home/issues/457)
tracks this scaling gap alongside the smaller-workload margin in #455.
The full 30-run snapshot `20260827T165255Z` preserves the loss: Home
855.8 ± 42.1 ms versus native TypeScript 7 at 382.3 ± 25.1 ms, or 2.24× slower.
The smaller predicate workload measures 67.6 ± 2.6 ms versus 74.7 ± 6.0 ms,
a 1.11× mean lead. All 18 projects pass the shared positive gate, and all 13
automatic negative controls pass in every compiler. Issues #455 and #457
remain open for the remaining general lookup and scaling costs.

Commit `0494dc6b6` for #457 indexes necessary named-shape member facts. Each
fact includes member count, string/number/symbol index-signature types, member
name/type, and optional/readonly/method flags. A missing fact proves that no
registered named object can satisfy the original shape comparison. Present
facts never accept a shape: the full comparison still handles combinations
from different objects, obsolete bindings, and hash collisions. This preserves
the original duplicate-member behavior without adding a quadratic uniqueness
scan. Facts follow the type-name table lifetime across source resets; an
allocation failure disables the filter. Regressions cover member order,
duplicates, modifiers, index signatures, ignored display metadata, rebinding,
false positives, source reset, and allocation failure.
The full checker suite passes 4,201 tests; the release build, all 18 shared
projects, and all 13 automatic negative controls pass for every compiler.
Alternating preserved before/after release binaries gives 67.73 ± 2.85 ms
versus 66.13 ± 6.46 ms on the small workload (30 samples per binary), and
800.16 ± 62.91 ms versus 645.06 ± 13.10 ms on the large workload (10 samples
per binary), each after three warmups. These development comparisons retain
every sample and are separate from the complete competitor snapshot.

Commit `3c6f4e69e` for #457 indexes local value declarations. A fresh profile on an
8,192-family diagnostic copy of the same generator identified local declaration
scans as the largest sampled leaf (357 samples); this diagnostic copy does not
replace either frozen benchmark. The index records first eligible declarations
and exact statement ordinals per container and virtual section. Lookups retain
the nearest-container rule, export-wrapper boundaries, and declaration-order
checks rather than comparing source spans. Empty and singleton containers keep
the original constant-sized scan. Failed index construction releases partial
state and falls back to the original scanner. Differential tests compare both
paths for every syntax node across nested blocks, namespaces, exports, multiple
virtual files, declaration kinds, shadowing, and missing names; allocation
failure tests cover each construction allocation and retry.
All 4,203 checker tests, the release build, 18 shared projects, and 13 negative
controls per compiler pass. Alternating preserved member-fact-only and
local-index binaries after three warmups measured 83.09 ± 20.83 versus
84.58 ± 26.97 ms for the small workload (30 samples each), and 740.15 ± 51.21
versus 632.05 ± 22.70 ms for the large workload (10 samples each). The small
comparison is noisy and does not show an improvement; all samples, including
the 206.09 ms new-binary observation, are retained. Concurrent unrelated
workstation jobs were observed during this development comparison.

The complete post-index snapshot `20260827T172600Z` retains all 30 interleaved
samples after three warmups across all 18 workloads. Home has lower means on
17 of 18; large predicates are 592.0 ± 14.6 ms versus native TypeScript 7 at
377.6 ± 18.3 ms and JavaScript TypeScript 6 at 1105.1 ± 100.4 ms, a 1.57×
loss to native TS 7. Small predicates are 74.1 ± 27.2 versus 91.7 ± 47.2 ms,
a noisy 1.24× mean lead. The full checker suite passes 4,203 tests, all 18
shared projects pass, and all 13 automatic negative controls pass in every
compiler. All 1,620 timed samples exit successfully. Issues #455 and #457
remain open: general type-display-name scans and relation-cache pressure
remain profiling targets, and this snapshot does not establish an everywhere
win or a reliable small-predicate margin.

Commit `403482530` for #457 avoids exact type-name scans for never-registered type
IDs. A fresh profile of the frozen large workload recorded 36 sampled leaves
in `knownTypeDisplayName`; the 8,192-family diagnostic recorded 406. A
monotonic set is populated at the single type-name registration path. Missing
membership proves no exact-ID match exists; obsolete membership only permits
the original scan. This deliberately does not infer absence from the reverse
display-name map: rebinding its selected name can remove that reverse entry
while another alias still refers to the original type. The set follows the
type-name table across source resets, and allocation failure disables the
filter. Regressions cover registration after a miss, alternate aliases after
rebinding, obsolete IDs, source lifetime, structural/class/alias precedence,
and allocation failure during registration.
All 4,206 checker tests, the release build, all 18 shared projects, and all 13
automatic negative controls per compiler pass. Alternating preserved binaries
after three warmups measured small predicates at 73.89 ± 15.23 versus
74.79 ± 20.16 ms (30 samples each), and large predicates at 679.77 ± 165.58
versus 556.70 ± 27.55 ms (10 samples each). These noisy development results
retain every observation, including a 1,128.47 ms old-binary large sample and
a 155.18 ms new-binary small sample; the small comparison shows no improvement.

Commit `8187216d7` addresses FIFO relation-cache tombstone accumulation.
A deterministic diagnostic used the production capacities, packed relation
keys, 16×capacity unique insertions, and the existing half-cache FIFO eviction.
Without maintenance, the 4,096-entry cache had 8,192 backing slots containing
4,096 live entries and 4,096 tombstones: no free slots to terminate misses.
The 16,384-entry cache had only one free slot among 32,768. Rehashing in place
at each existing eviction boundary retained the same live entries and restored
4,096 and 16,384 free slots respectively. Both cache levels now perform this
allocation-free maintenance without changing capacity, FIFO order, pending
markers, or promotion behavior. A regression first failed on retained
tombstones, then passed with rehashing; it checks 512 insertions per level,
all retained/evicted results, pending-to-final overwrites, unchanged overwrite
order, and zero allocation attempts after reserving capacity.
All 4,207 checker tests, the release build, the 18 shared projects, and all 13
negative controls per compiler pass. The isolated cache-maintenance comparison
ran under substantial concurrent workstation activity: small
predicates were 112.81 ± 19.02 versus 114.80 ± 29.86 ms (30 samples each), and
large predicates were 940.16 ± 112.91 versus 1009.84 ± 243.44 ms (10 samples
each), after three warmups. Both new-binary means are higher in this comparison;
it does not demonstrate a timing improvement. All observations are retained,
including the 225.53 ms small and 1,537.53 ms large new-binary samples. The
deterministic tombstone regression establishes the corrected cache behavior,
not an end-to-end speedup by itself.
A fresh 8,192-family diagnostic profile after both changes no longer lists
exact type-name scanning or relation-cache lookup/insert among its leading
sampled leaves. Named-object shape comparisons lead with 390 samples, followed
by string comparisons at 338. This identifies the next profiling target; the
different profiles are not interchangeable timing measurements.

The full post-maintenance snapshot `20260827T174752Z` records 17/18 lower
Home means. Large predicates remain a loss: Home 557.5 ± 157.8 ms versus
native TypeScript 7 at 380.1 ± 23.4 ms and JavaScript TypeScript 6 at
1152.4 ± 255.2 ms, or 1.47× slower than the faster competitor. Small
predicates are 66.6 ± 3.8 versus 82.4 ± 26.5 ms, a 1.24× mean lead.
All 1,620 timed samples exit successfully, after all 18 positive projects
and all 13 negative controls pass in each compiler. Both published tables
match the raw data, and the frozen predicate hashes are unchanged.
[Issue #455](https://github.com/home-lang/home/issues/455) and
[issue #457](https://github.com/home-lang/home/issues/457) stay open for the uncertain small margin and remaining scaling
loss. Named-object shape comparisons are the next profiled target; any further
index must preserve member-order/duplicate behavior, binding lifetime, class
preference, and diagnostic-name selection rather than changing checked work.

Commit `4fccb476d` for #457 upgrades necessary member facts into candidate
buckets backed by a contiguous list. A valid named shape must occur in every
queried member's bucket, so the smallest bucket is a complete candidate set.
The query still checks each current name-to-TypeId binding, class preference,
and the original complete shape comparison. Duplicate member facts, repeated
registrations, stale bindings, and hash collisions cannot accept an invalid
shape. A unique matching name can return directly; multiple distinct matching
names fall back to the original table scan, preserving its diagnostic-name
selection order. This avoids depending on hash-table layout or imposing a new
name preference. Candidate storage follows the type-name table lifetime across
source resets. Failed bucket or list allocation disables the index and keeps
the original scanner. Differential regressions cover ambiguity across table
growth, class preference, member permutations and duplicates, exact-self
exclusion, rebinding, source lifetime, forced collisions, and both allocation
failure points.
All 4,209 checker tests, the release build, all 18 shared projects, and all 13
negative controls per compiler pass. Alternating preserved binaries after
three warmups measured small predicates at 78.63 ± 16.01 versus 80.22 ± 21.36
ms (30 samples each), and large predicates at 547.59 ± 51.70 versus
535.67 ± 38.06 ms (10 samples each). All samples are retained, including the
156.78 ms new-binary small sample. The large mean difference is modest relative
to the variability; this development comparison does not establish a robust
end-to-end improvement, and the small mean is higher.

The follow-up 8,192-family diagnostic profile no longer lists named-shape
comparison among its leading sampled leaves. String comparison leads with
420 samples; `isBuiltinName` is a recurring caller and has 49 direct leaf
samples. Its fixed spelling list (308 entries, 266 distinct spellings) is now
represented by a compile-time static string set in commit `5a537e057`, preserving the exact list,
duplicates, and case-sensitive lookup
without runtime allocation. `ITextWriter` still checks the attached source's
first `@lib` line, and the existing `Iterator`, `fetch`, and `Image` exceptions
remain unchanged. Focused regressions exercise every original list entry,
prefixed/suffixed misses, case variants, empty and non-ASCII names, no-source
behavior, and library-directive changes across source resets.
All 4,211 checker tests, the release build, the 18 shared projects, and all 13
negative controls per compiler pass. Alternating preserved candidate-index
and static-builtin binaries after three warmups measured small predicates at
74.68 ± 5.84 versus 69.55 ± 5.19 ms (30 samples each), and large predicates at
550.26 ± 33.58 versus 501.64 ± 11.87 ms (10 samples each). Every observation
is retained; the full competitor snapshot remains the basis for suite claims.
The post-change diagnostic profile records only two string-equality samples
directly under `isBuiltinName`. Most remaining string-equality samples are
under substring searches (294), including source setup, driver setup, program
collection passes, and directive queries. The next investigation should
attribute these repeated whole-source searches and preserve their exact
matching semantics; these profile counts are not timing speedups.

The full snapshot `20260827T181303Z` retains all 30 interleaved samples after
three warmups across 18 workloads, with 17/18 lower Home means. Large predicates
remain slower: Home 549.4 ± 87.3 ms, native TypeScript 7.0.2 460.4 ± 126.6 ms,
and JavaScript TypeScript 6.0.3 1369.6 ± 302.2 ms, a 1.19× loss to the faster
competitor. Small predicates are 64.8 ± 3.7 versus 83.2 ± 5.9 ms, a 1.28×
mean lead. Several later workloads have substantial variance during unrelated
workstation activity; neither the narrower ratio nor cross-session absolute
times isolate an optimization's effect. All 1,620 timed samples succeeded,
both tables match the raw data, and all 18 positive projects plus 13 negative
controls passed in every compiler. The full checker suite passes 4,211 tests.
Issues #455 and #457 remain open. Next work will investigate repeated
whole-source searches in setup, program collection, and directive handling
without weakening their matching semantics or benchmark inputs.

Commit `b1fe7c9f4` for #457 shares exact source-marker searches. A compile-time
byte automaton records the first position of each fixed substring in one
allocation-free pass, replacing independent setup searches and supplying
positions to existing directive parsers. Comments, strings, identifier
substrings, overlapping matches, and non-ASCII bytes retain the behavior of
independent `std.mem.indexOf` calls. The `require` prefilter retains its
identifier-boundary check. Directive parsing is unchanged, including uppercase
`@noLib` precedence over lowercase `@nolib`, first valid `@checkJs`/`@allowJs`
selection, and their existing case rules. Source replacement rebuilds the
index and clears the original caches. Virtual-filename queries return early
only when the source has neither recognized filename marker.
Differential regressions cover arbitrary generated bytes, overlaps and suffixes,
every setup feature flag, source resets, no-source/index fallback, and directive
precedence and casing. All 4,216 checker tests, the release build, all 18 shared
projects, and all 13 negative controls per compiler pass. Both predicate source
hashes remain unchanged.

The alternating preserved-binary development comparison uses three warmups,
30 small-predicate samples and 10 large-predicate samples per binary. Small
predicates measure 76.87 ± 8.88 ms before and 72.92 ± 9.33 ms after; large
predicates measure 522.19 ± 26.59 and 511.00 ± 59.31 ms. Every observation is
retained, including the new-binary 667.54 ms large sample. These differences are
modest relative to the variability and do not establish a robust end-to-end
speedup. The full interleaved competitor snapshot is the basis for suite claims.

Commit `59b4ad1c8` also adds an exact compiler-version preflight. Its five
regressions cover matching pins, stale TS 6 installs, the old
`7.0.0-dev.20260707.2` native build, prerelease suffixes, and rejection before
any result directory or workload timing is created. Both installed compilers
verify as `Version 6.0.3` and `Version 7.0.2`; the benchmark corpus and measured
commands are unchanged.

The full snapshot `20260827T183613Z` retains all 30 interleaved samples after
three warmups across 18 workloads. Home has 17/18 lower means. Large predicates
remain slower: Home 491.0 ± 54.1 ms, native TypeScript 7.0.2 430.2 ± 40.9 ms,
and JavaScript TypeScript 6.0.3 1278.3 ± 203.3 ms, a 1.14× loss to the faster
competitor. Small predicates measure 76.1 ± 8.6 versus 127.7 ± 15.2 ms,
a 1.68× mean lead. The different workstation conditions and substantial
variance prevent attributing the cross-session ratio change to this commit
alone. All 1,620 timed samples succeeded; balanced compiler ordering, exact
versions, both complete published tables, and frozen predicate hashes were
verified against the raw data. All positive projects and negative controls
passed in each compiler, alongside 4,216 checker tests and five harness tests.
Issues #455 and #457 remain open.

A separate post-run 8,192-family diagnostic profile still attributes 151 of
188 string-equality samples to substring searches. Recurring non-memory
callers include checker and driver setup, program namespace/interface/class
collection, and source-based self-assignment checks. These sample counts guide
the next investigation; they are not speedup measurements or an additional
accepted benchmark. Next work should reuse immutable source facts across
driver/program collection and inspect the remaining prefix searches while
preserving directive parsing, source-update lifetimes, and full type checking.

Commit `f18dd5662` targets repeated driver directive-line scans. The diagnostic
profile attributed 32 scalar-search samples to compiler-option values, 14 to
boolean directives, six to simple directive values, and three to JSX directive
detection. Each parser previously split every source line, although any
accepted directive must contain `@`. An allocation-free candidate-line iterator
now jumps to the next `@` using byte search and returns its complete original
line exactly once. Parsing rules remain unchanged: the first `@` on a line,
case and identifier-boundary rules, malformed or empty values, duplicate-line
order, and parser-specific first-match behavior all retain their prior meaning.
This changes neither tokenization nor type checking and adds no source cache.

Differential tests compare candidate contents and source offsets with
`splitScalar` filtered for `@`, covering arbitrary generated bytes, repeated
lines, embedded markers, CRLF, lone CR, empty input, and EOF. Driver regressions
exercise differing value/boolean parser behavior and JSX directive precedence.
All 173 driver tests, five harness tests, the release build, all 18 shared
projects, and all 13 negative controls per compiler pass. Both predicate hashes
are unchanged.

Alternating preserved binaries after three warmups measured small predicates
at 57.39 ± 3.51 ms before and 54.55 ± 3.26 ms after (30 samples per binary),
and large predicates at 461.76 ± 56.34 versus 426.87 ± 25.74 ms (10 each).
All observations are retained, including the 613.49 ms baseline large sample.
The lower means favor the change, but the large-case variability and outlier
limit the strength of that end-to-end inference; the full interleaved competitor
snapshot remains the basis for suite claims.

The full snapshot `20260827T185149Z` retains all 30 interleaved samples after
three warmups across 18 workloads, with 17/18 lower Home means. Large predicates
remain slower: Home 399.7 ± 25.6 ms, native TypeScript 7.0.2 338.0 ± 16.1 ms,
and JavaScript TypeScript 6.0.3 969.2 ± 31.0 ms, a 1.18× loss to the faster
competitor. Small predicates measure 53.3 ± 0.8 versus 74.6 ± 2.8 ms,
a 1.40× mean lead. All 1,620 timed samples succeeded, and balanced ordering,
exact versions, both complete tables, and frozen predicate hashes were
verified. All 18 positive projects and 13 negative controls pass per compiler;
173 driver tests and five harness tests pass. The unchanged 4,216-test checker
gate also passes from cache. No samples were removed. Some rows remain noisy,
and lower absolute times across sessions do not isolate this commit's effect.

The original small-predicate margin tracked in
[issue #455](https://github.com/home-lang/home/issues/455) is now materially
stronger than its initial 1.05× lead, with the accepted input and configuration
unchanged. This addresses that narrow issue, not universal performance:
[issue #457](https://github.com/home-lang/home/issues/457) remains open for the
large-case loss, and #416 continues to track broader coverage and optimization.

The separate post-run 8,192-family diagnostic profile records only five scalar
search samples under the three changed value/boolean directive parsers, while
program collection and other substring searches remain recurring callers.
Raw builtin lowering has 109 inclusive samples, with leading stacks in the
fixed `Function` signature construction invoked by predicate matching.
Source-based self-conditional-assignment checks also remain prominent.
These are profiling observations, not speedup measurements. The next step is
to check which repeated builtin constructions can be safely reused while
preserving rest-signature metadata and allocation-failure behavior, alongside
the remaining program/source-prefix work.

Commit `b5b5bd938` reuses the fixed internal member recipe for builtin
`Function`: its private `any[]` parameter type and two rest signatures. The
outer object still receives a fresh TypeId on every request, preserving the
existing declaration-identity behavior. The cache is published only after
complete successful construction and shares the checker/interner lifetime;
source replacement does not invalidate these immutable components or their
rest-signature metadata. A cached construction now adds one type instead of
rebuilding all four constituent types.

Three regressions cover structural equivalence with the original constructor,
fresh outer identities, member/parameter/return types, diagnostic names,
rest metadata, source replacement, and cold/cached allocation-failure sweeps
with recovery and leak checks. All 4,219 checker tests, 173 driver tests,
five harness tests, and the release build pass. All 18 positive projects and
13 negative controls pass per compiler; both predicate hashes remain unchanged.

Alternating preserved binaries after three warmups measured large predicates
at 387.24 ± 4.63 ms before and 361.42 ± 7.86 ms after (10 samples each),
about 6.7% lower mean time. Small predicates measured 59.61 ± 25.74 versus
58.96 ± 33.74 ms (30 each), with medians of 52.20 and 48.58 ms. All samples
are retained, including baseline/candidate maxima of 168.10/222.29 ms.
The noisy small-case means do not establish a clear improvement. Unrelated
workstation activity was present, and a source-format check overlapped part
of the paired comparison; these observations are not a controlled estimate
of compiler-only execution time.

The identity audit also found a pre-existing semantic discrepancy tracked in
[issue #467](https://github.com/home-lang/home/issues/467): with a declared
global `Function` containing a `call` method, direct and aliased predicates
fail to narrow a number/function union in Home, although both pinned
competitors accept the typed calls. An empty global `Function` is a distinct
control that correctly retains the union in TS 6 and TS 7. Ordinary assignment
of a function to the nonempty global `Function` already succeeds in Home.
The optimization preserves the baseline's three diagnostics exactly; it does
not fix or conceal that discrepancy, and this diagnostic probe is not an
accepted or timed benchmark. A separate shape-aware semantic correction is
required before #467 can close.

The full snapshot `20260827T191750Z` retains all 30 interleaved samples after
three warmups across 18 workloads, with 17/18 lower Home means. Large predicates
measure Home 379.3 ± 15.8 ms, native TypeScript 7.0.2 356.0 ± 20.1 ms,
and JavaScript TypeScript 6.0.3 1012.4 ± 56.3 ms: Home remains 1.07× slower
than the faster competitor. Small predicates measure 47.4 ± 0.9 versus
69.5 ± 2.3 ms, a 1.47× mean lead. All 1,620 timed samples succeeded;
540 complete rounds, balanced compiler order, exact versions, both tables,
and frozen predicate hashes were verified. All positive projects and negative
controls passed before timing. No samples were discarded or replaced.
The large-case performance issue #457 and broader tracker #416 remain open.

A separate post-run 8,192-family diagnostic profile records 28 inclusive
samples in raw builtin lowering. Substring searches remain prominent, including
program collection and checker/driver setup, while source-based direct
self-conditional-assignment checks account for 34 top-of-stack samples.
These counts identify further investigation targets, not speedup estimates or
an additional accepted benchmark. Next work should inspect repeated program
collection and source-prefix scans while preserving declaration visibility,
source-update lifetimes, and semantic checks.

Commit `dad87a665` removes impossible direct self-conditional-assignment scans.
The existing helper can only return true if the preceding semicolon-delimited
segment contains `?` in the selected assignment's RHS. An exact source-level
absence check now reuses the shared byte-marker index, and a segment-level
absence check rejects other segments before searching for identifier text.
The original assignment, identifier-boundary, and RHS checks still run for
candidates. No tokenization or type-checking rule changes; question marks in
comments and strings retain their original byte-scanning behavior.

Two regressions compare against the original implementation at every source
offset, including beyond EOF, with multiple names, generated bytes, CRLF,
comments/strings, semicolons inside strings, assignment lookalikes, and repeated
assignment candidates. They cover both cached and uncached marker lookup,
positive matches, null source, and repeated source replacement. All 4,221
checker tests, 173 driver tests, five harness tests, and the release build
pass. All 18 shared projects and 13 negative controls pass per compiler;
both predicate hashes remain unchanged. The release toolchain is
Zig `0.17.0-dev.1441+d5181a9c9`, using `ReleaseFast`.

Alternating preserved binaries after three warmups measured small predicates
at 49.30 ± 0.32 ms before and 45.39 ± 0.37 ms after (30 samples each).
Large predicates measured 415.61 ± 44.11 versus 375.56 ± 46.66 ms (10 each),
with medians of 393.78 and 361.44 ms. All observations are retained, including
the 500.35 ms candidate sample. Control flow measured 36.30 ± 2.84 versus
35.45 ± 0.83 ms (30 each), with medians of 35.49 and 35.23 ms and a 50.46 ms
baseline maximum; this does not establish a robust control-flow improvement.
The small-predicate result is consistent, but the large-case variability and
concurrent workstation activity limit the strength of that mean comparison.

The full snapshot `20260827T193257Z` retains all 30 interleaved samples after
three warmups across 18 workloads. Home has a lower mean on all 18, but large
predicates are a near tie: Home 326.0 ± 10.0 ms versus native TypeScript 7.0.2
326.6 ± 8.3 ms, with JavaScript TypeScript 6.0.3 at 956.6 ± 37.9 ms. Home's
0.2% mean advantage is small relative to the observed variability; medians are
323.18 and 324.02 ms. This does not establish a convincing lead, so
[issue #457](https://github.com/home-lang/home/issues/457) remains open for a
robust large-case margin. Small predicates measure 42.8 ± 1.7 versus
68.4 ± 2.0 ms, a 1.60× mean lead. All 1,620 timed samples succeeded;
540 complete rounds, balanced compiler order, exact versions, both tables,
and frozen predicate hashes were verified. No samples were discarded.

Commit `999258e16` makes the report's rounded-equal ratios explicitly say
`1.00× (near tie)` instead of displaying a misleading directional win. Five
regressions cover equality, either direction, and the symmetric two-decimal
boundary; all ten harness/report tests pass. This only changes presentation,
not measurements or their aggregation, and does not claim statistical
significance for larger displayed ratios.

A separate post-run 8,192-family diagnostic profile records only two
inclusive samples in the filtered self-conditional-assignment helper.
Repeated substring searches remain in program ambient-interface, namespace,
class, and CommonJS collection, alongside checker/driver setup. These counts
guide the next investigation, not a speedup claim or a new accepted benchmark.
Next work should share exact program source facts while auditing source
replacement, redirects, and declaration visibility. The broader #416 goal,
the #457 narrow margin, #467 semantic discrepancy, and #464 unvalidated
container harness all remain open.

Commit `d33019821` shares exact program-source marker searches across 19
existing collection prechecks. Nine byte markers cover namespace/global,
ambient interface, class, augmentation, and CommonJS collection. The existing
matcher implementation is reused; collection parsers, identifier rules, and
declaration visibility are unchanged. Matches inside comments, strings, and
larger identifiers retain the original byte-search meaning.

Each serial, streaming, or parallel compilation entry builds a transient
snapshot for non-redirected files and clears it on every exit. Redirect sources
are excluded before reading their bytes. Source replacement invalidates the
snapshot, and calls outside a collection pass retain the original searches.
Snapshot construction adds no allocation path or retained source ownership.

Four new regressions compare exact first positions on generated bytes,
nonempty metadata from all six affected collection categories with and without
snapshots, source replacement and redirect exclusion, and successful/error
cleanup in all three compilation entry points. All 99 program tests,
4,221 checker tests, 173 driver tests, ten harness/report tests, and the final
release build pass. All 18 shared projects and 13 negative controls pass per
compiler, with frozen predicate hashes unchanged.

Alternating preserved binaries after three warmups measured small predicates
at 46.73 ± 6.07 ms before and 43.23 ± 0.75 ms after (30 samples each),
with medians of 45.18 and 43.27 ms. Large predicates measured
355.52 ± 21.14 versus 332.16 ± 7.11 ms (10 each), with medians of
348.05 and 330.08 ms. Many files measured 32.21 ± 1.53 versus
30.88 ± 1.35 ms (30 each). Every observation is retained, including baseline
maxima of 77.06 ms on small predicates and 413.82 ms on large predicates.
The lower means and medians favor the change, but concurrent workstation
activity and baseline outliers limit the inference from these paired samples.

The lifetime audit separately identified pre-existing source-update risks,
tracked in [issue #472](https://github.com/home-lang/home/issues/472): failure
after removing the old source-map entry can leave inconsistent state, and
canonical source replacement does not refresh borrowed redirect slices.
This is a source-level finding awaiting dedicated failure/recovery tests;
the transient snapshot optimization does not claim to fix those semantics.

The full snapshot `20260827T195539Z` records 18/18 lower Home means across
30 interleaved rounds after three warmups. Large predicates measure
323.8 ± 10.2 ms for Home, 351.4 ± 15.2 ms for native TypeScript 7.0.2,
and 1010.4 ± 25.3 ms for JavaScript TypeScript 6.0.3: a 1.09× Home mean lead.
Small predicates measure 41.9 ± 0.8 versus 70.9 ± 2.0 ms, a 1.69× lead.

The independent large-predicate confirmation was declared before inspecting
the full-run results. Snapshot `20260827T200026Z` retains another 30 rounds
after three warmups: Home 327.1 ± 10.4 ms, native TS 7 359.7 ± 14.2 ms,
and TS 6 1026.1 ± 37.1 ms, a 1.10× Home mean lead. Home was faster than
native TS 7 in 29/30 paired large-case rounds of the full run and 30/30 in
the confirmation. The full-run table above is not replaced or averaged with
the confirmation. Both runs retain every observation, including their
outliers and variability.

Commit `d8e32bd9d` adds reproducible workload selection for these confirmations.
Six regressions cover the unchanged full-suite default, requested order,
empty/unknown/duplicate rejection, and failure before creating result files.
All 16 harness/report tests pass. Selection does not alter project inputs,
negative controls, compiler flags, timing, or sample aggregation.

All 1,710 timed samples succeeded. The 540 full-suite and 30 confirmation
rounds, exact versions, balanced ordering, selected-workload metadata,
published tables, frozen predicate hashes, and preserved release binary were
verified. The repeated local lead addresses the frozen scaling case tracked
in [issue #457](https://github.com/home-lang/home/issues/457); it does not prove
performance on other projects or machines. The earlier losses and near tie
remain in this history.

A separate post-run 8,192-family diagnostic profile still shows repeated
checker/driver setup and remaining ambient-interface collection searches.
These counts guide further work and are not timing claims. The broader #416
goal remains open: next coverage is dedicated async/await type propagation
under [issue #473](https://github.com/home-lang/home/issues/473), followed by
validated real-world projects and cross-platform measurements. Semantic
issues #467 and #472 and the unvalidated container path #464 remain open.

<details>
<summary>Previous full snapshot: 20260827T195539Z, commit d33019821</summary>

| Workload | tsc 6.0.3 | native TS 7.0.2 | Home 0.1.0 | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 66.7 ± 2.5 ms | 42.0 ± 9.6 ms | **3.6 ± 0.4 ms** | **11.73× faster** |
| `many_files` | 215.4 ± 3.3 ms | 56.7 ± 7.5 ms | **32.4 ± 6.3 ms** | **1.75× faster** |
| `deep_types` | 146.0 ± 8.6 ms | 58.3 ± 3.7 ms | **14.1 ± 0.8 ms** | **4.12× faster** |
| `import_graph` | 139.0 ± 4.4 ms | 49.8 ± 4.1 ms | **29.3 ± 2.0 ms** | **1.70× faster** |
| `reexport_graph` | 111.0 ± 46.4 ms | 47.0 ± 19.2 ms | **31.1 ± 6.1 ms** | **1.51× faster** |
| `tsx_components` | 178.0 ± 25.2 ms | 50.2 ± 1.6 ms | **23.3 ± 4.1 ms** | **2.16× faster** |
| `generic_calls` | 188.4 ± 12.9 ms | 57.3 ± 3.9 ms | **23.2 ± 2.0 ms** | **2.47× faster** |
| `control_flow` | 190.2 ± 4.8 ms | 59.5 ± 2.2 ms | **33.6 ± 5.4 ms** | **1.77× faster** |
| `type_predicates` | 237.8 ± 12.7 ms | 70.9 ± 2.0 ms | **41.9 ± 0.8 ms** | **1.69× faster** |
| `type_predicates_large` | 1010.4 ± 25.3 ms | 351.4 ± 15.2 ms | **323.8 ± 10.2 ms** | **1.09× faster** |
| `null_safe_access` | 191.9 ± 4.1 ms | 57.2 ± 1.1 ms | **38.7 ± 0.5 ms** | **1.48× faster** |
| `destructuring` | 138.4 ± 1.6 ms | 47.3 ± 1.0 ms | **34.4 ± 0.5 ms** | **1.37× faster** |
| `overload_resolution` | 203.1 ± 3.4 ms | 64.6 ± 1.4 ms | **29.1 ± 0.6 ms** | **2.22× faster** |
| `class_hierarchy` | 186.1 ± 7.9 ms | 53.4 ± 7.8 ms | **28.1 ± 0.4 ms** | **1.90× faster** |
| `structural_objects` | 185.8 ± 2.9 ms | 58.1 ± 1.6 ms | **30.3 ± 0.6 ms** | **1.92× faster** |
| `interface_composition` | 214.9 ± 41.7 ms | 64.7 ± 4.3 ms | **45.6 ± 6.0 ms** | **1.42× faster** |
| `variadic_tuples` | 252.9 ± 6.3 ms | 77.7 ± 2.5 ms | 42.4 ± 1.0 ms | Provisional: older admission schema |
| `checkjs_jsdoc` | 211.5 ± 27.6 ms | 54.3 ± 1.2 ms | **36.9 ± 0.9 ms** | **1.47× faster** |

</details>

### Async admission audit and primitive return contracts

Before adding async/await to the measured suite,
[issue #473](https://github.com/home-lang/home/issues/473) checks a candidate
project with identical strict, ES2022, `noLib`, `skipLibCheck`, and `noEmit`
options for all three compilers. Promise, PromiseLike, Awaited, and
PromiseConstructor declarations are extracted unchanged from TypeScript
6.0.3's `lib.es5.d.ts` and `lib.es2015.promise.d.ts`; the shared minimal
global declarations remain unchanged. The candidate exercises generic async
projections, thenable assimilation, optional/discriminated result consumption,
typed async returns, Promise chains, and readonly tuple inputs to Promise.all.
It is **not an accepted benchmark and has no published timing**.

The initial audit found both false rejection of a valid generic async
projection and false acceptance of wrong Promise-chain/tuple result types.
Those remain open in [#476](https://github.com/home-lang/home/issues/476) and
[#475](https://github.com/home-lang/home/issues/475). The workload will not be
weakened or timed while those correctness controls fail.

It also exposed a broader return-checking gap: ordinary primitive return
contracts were checked only in special cases, affecting synchronous functions
as well as async functions. Commit `9e45e105d`, tracked in
[#474](https://github.com/home-lang/home/issues/474), applies the existing
assignability check to canonical primitive returns generally, including
`unknown` sources and strict-null unions. Async bodies check the awaited
value against the awaited declared result. Block callbacks retain their
actual inferred returns so the enclosing call can reject an incompatible
signature instead of replacing its result with the expected type. Obsolete
paired-setter-specific gating was removed.

Five regression groups and independent release-CLI checks use the same source
for Home, TS 6.0.3, and native TS 7.0.2. Each TypeScript baseline produces the
expected diagnostics below; Home's pre-change counts use the preserved
`d33019821` compiler. The non-strict group explicitly disables strict null
checks for every compiler.

| Shared correctness probe | Expected from each TS baseline | Home before | Home after |
|---|---|---:|---:|
| Wrong synchronous primitive returns | 5 × TS2322 | 0 | 5 |
| Wrong direct, promised, awaited, branch, and arrow async returns | 5 × TS2322 | 1 | 5 |
| Unknown and strict nullish return values | 5 × TS2322 | 2 | 5 |
| Non-strict nullish and any return values | No errors | 0 | 0 |
| Valid constrained/narrowed returns plus one invalid block callback | 1 × TS2345 | 0 | 1 |

These are rejection and diagnostic-code checks, not byte-for-byte parity:
[#478](https://github.com/home-lang/home/issues/478) tracks async error text
that still names the syntactic Promise annotation instead of its awaited
target, including an expression-arrow discrepancy present before this fix.
All 4,226 checker tests, 99 program tests, 173 driver tests, and 16 benchmark
harness/report tests pass. All existing 18 positive projects and 13 negative
controls per compiler pass; the small and large predicate hashes remain
unchanged. No compiler options or timed project inputs were weakened.

The post-fix full snapshot `20260827T202656Z` retains 30 interleaved rounds
after three warmups for all 18 existing workloads. Home has a lower mean in
every row. Large predicates measure Home 322.1 ± 13.3 ms, native TS 7
348.8 ± 15.7 ms, and TS 6 1027.8 ± 117.6 ms: a 1.08× mean lead over the
faster competitor. Small predicates measure 46.5 ± 19.5 versus
72.4 ± 10.8 ms, a 1.56× lead. These are measurements with stronger return
validation, not a claim that the correctness fix itself made checking faster.

The separately predeclared confirmation `20260827T203044Z` retains another
30 large-predicate rounds after three warmups: Home 342.5 ± 29.3 ms,
native TS 7 370.2 ± 22.0 ms, and TS 6 1086.3 ± 96.2 ms, again a 1.08×
Home mean lead. Home was faster than native TS 7 in 29/30 paired large-case
rounds in the full suite and 26/30 in the confirmation. The confirmation
is neither substituted for nor averaged into the main table.

Every one of the 1,710 timed samples succeeded. All 540 full-suite rounds
and 30 confirmation rounds were checked for complete results, exact compiler
versions, balanced order, one retained sample per compiler, and successful
exit codes. The release binary and frozen predicate hashes were verified.
Variance remains material: the full-run TS 6 control-flow standard deviation
is 127.9 ms, and Home's small-predicate standard deviation is 19.5 ms.
Both runs, including every outlier, remain in the record. These local synthetic
results do not establish leadership on real projects or other platforms.
Issues #473, #475, #476, and #478 remain open before async coverage can be accepted.

### Generic receiver callback validation (untimed)

Commit [`0612a9071`](https://github.com/home-lang/home/commit/0612a9071fd4231f0fce1f3e15c948ec2a3d503d)
fixes [#479](https://github.com/home-lang/home/issues/479), an underlying
generic-call failure found during the async admission audit. A callback such
as `mapper.project(value => value.label)` now retains the instantiated receiver
parameter and infers its actual return type. Previously, an unresolved method
return parameter prevented contextual parameter typing, and later re-lowering
of the declaration discarded the receiver's substitutions.

The fix operates on instantiated types, carries context into nested arrows and
explicit generic calls, and retains key-dependent indexed accesses until their
keys are inferred. Uniform string dictionaries still reduce to their
key-independent value type. Already-checked callbacks with identical contextual
types are reused; repeated checks do not duplicate an identical return error.

The six [regression sources](https://github.com/home-lang/home/blob/0612a9071fd4231f0fce1f3e15c948ec2a3d503d/packages/ts_checker/src/check.zig#L232408)
were checked with TS 6.0.3, native TS 7.0.2, and Home, each as both a global
script and an export-marked module. Every compiler receives identical
strict/noEmit/noLib/skipLibCheck/ES2022 inputs, the shared minimal library, and
unchanged Promise declarations from TS 6.0.3's `lib.es5.d.ts` and
`lib.es2015.promise.d.ts`. These declarations also prevent missing-global-type
errors during callback compatibility checks; they are not simplified facades.

| Untimed regression family | Expected diagnostics per invalid project | TS 6 / TS 7 / Home |
|---|---|---|
| Inferred receiver callback result | 1 × TS2322 | All match |
| Block, function-expression, and explicit callbacks | 3 × TS2322 | All match |
| Nested callbacks and distinct receiver types | 3 × TS2322 | All match |
| Constraints, defaults, and shadowed type parameters | 4 × TS2322 | All match |
| Incompatible callback arguments and missing properties | TS2322, TS2345, TS2339 | All match |
| Inferred indexed rest payloads | 3 × TS2322 | All match |

Removing only the deliberately invalid statements produces twelve valid
projects per compiler; all are accepted. Each compiler also reports the
expected diagnostic-code multisets for all twelve invalid projects, totaling
72 CLI checks across the three compilers. This verifies acceptance and
diagnostic codes, not byte-for-byte diagnostic parity. The local audit directory
is `bench/vs_tsgo/results/receiver-audit.eg3jPC`.

All 4,232 checker tests, 99 program tests, 173 driver tests, and 16 benchmark
harness/report tests pass. The final ReleaseFast binary also passes validation
of all 18 existing workloads and all 13 existing negative controls per compiler.
Both frozen predicate source hashes are unchanged. The focused checker cases
can be reproduced with:

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='generic interface callbacks'
```

No new timings were collected during the concurrent workstation build/test
activity. The main table and README therefore remain the measured
`9e45e105d` snapshot, not measurements of `0612a9071`. Removing redundant
callback checks is not, by itself, evidence of an end-to-end speedup.

The post-fix async audit still finds that Home accepts the invalid Promise
chain and `Promise.all` result controls rejected by both baselines
([#475](https://github.com/home-lang/home/issues/475)), and rejects the valid
generic async projection accepted by both
([#476](https://github.com/home-lang/home/issues/476)). A separate ordinary
interface/static-method probe confirms that global-script declarations are
erased to `any` while module declarations retain their types; this is tracked in
[#480](https://github.com/home-lang/home/issues/480), without Promise-specific
exceptions. Those issues and the async diagnostic-text issue
[#478](https://github.com/home-lang/home/issues/478) remain open under
[#473](https://github.com/home-lang/home/issues/473). Async remains untimed, and
the accepted workload count remains 18.

### Global declaration and graph admission audit (untimed)

The cross-file audit exposed a flaw in the earlier admission evidence: positive
projects can pass when imported types have been erased to `any`. Two existing
workloads fail direct negative controls, tracked in
[#487](https://github.com/home-lang/home/issues/487):

| Existing workload, invalid statements appended to a temporary copy | TS 6.0.3 / native TS 7.0.2 | Home |
|---|---|---|
| `import_graph`: assign `result.current` to `number`; read `result.missing` | TS2322 and TS2339 | Incorrectly accepts |
| `reexport_graph`: assign `value0.value` to `string`; read `value0.missing` | TS2322 and TS2339 | Incorrectly accepts |

The original projects are unchanged. These controls exercise the imported
generic types, not locally redeclared substitutes. Both controls are now part
of workload validation. The full selection must pass before any timing,
warmup, result directory, or metadata is created. The actual default run was
checked to stop at `import_graph` without creating results. The graph workloads
remain in the default suite; they are not silently removed to produce a pass.

New runs record admission schema 2 after validation. The report generator
retains all old graph measurements but labels pre-schema-2 graph comparisons
ineligible. The main table and README withdraw those two speed claims, and the
same correction applies to historical tables above. Other workloads need
broader rejection coverage; the remaining sixteen rows are not a claim of
sixteen proven-equivalent semantic workloads. The predicate and destructuring
controls remain useful evidence for their specific checks.

No new timing results were collected under the concurrent workstation load.
The old `9e45e105d` times and raw observations are retained unchanged. Fixing
cross-file types and re-running admission are prerequisites to graph retiming,
not evidence of a speedup themselves. The local evidence directory is
`bench/vs_tsgo/results/global-audit.TExK7j`.

The implementation checkpoint consists of
[`98176963c`](https://github.com/home-lang/home/commit/98176963c5ab6422c86e12139cc459f202aa1c05)
(resolve actual/forward declarations before global-name fallback),
[`6cba2f248`](https://github.com/home-lang/home/commit/6cba2f248445646302d1df6a02e07a299c4a2c1a)
(keep narrowed runtime values separate from type lookup), and
[`8a737cdb2`](https://github.com/home-lang/home/commit/8a737cdb208c0bab3ca518880eaf8c486705ba13)
(resolve explicit project files relative to the config directory, fixing
[#483](https://github.com/home-lang/home/issues/483)). The graph gate and
historical-report correction are in
[`16f84e743`](https://github.com/home-lang/home/commit/16f84e74365d42296bee71195dc645f5e0def376).

The [reproducible global audit](https://github.com/home-lang/home/blob/50abd827a75cbd94bdb29acb37f79ca39b88f369/bench/vs_tsgo/audit_globals.py)
uses identical strict/noEmit/noLib/skipLibCheck projects and the shared minimal
library. Same-file cases cover ordinary/generic methods, aliases, forward
declarations, merging, type/value-name coexistence, and module-local isolation.
Cross-file cases cover interfaces, same-named local values, generic static
methods, declared variables, and merging, each with declarations explicitly
listed before and after the app. Positive controls retain the declarations and
remove only the invalid statements. Passes below mean acceptance or the expected
diagnostic-code multiset, not byte-for-byte diagnostic parity.

| Untimed audit | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Same-file declarations: 12 valid + 12 invalid projects | 24/24 | 24/24 | 24/24 |
| Cross-file globals: 10 valid + 10 invalid projects | 20/20 | 20/20 | 6/20 |
| Project/build/positional path controls | 6/6 | 6/6 | 6/6 |
| Existing generic receiver callback controls | 24/24 | 24/24 | 24/24 |

The default global audit performs 132 checks and intentionally exits nonzero:
all fourteen failures are Home cross-file cases. It does not waive or hide
known failures. Both root orders expose the same gaps. The path checks run from
outside the project, include relative, parent-relative, and absolute file
entries, and preserve positional-file behavior with explicit `--ignoreConfig`.
The missing TS5112 diagnostic when that flag is absent is separately tracked in
[#486](https://github.com/home-lang/home/issues/486).

```sh
python3 bench/vs_tsgo/audit_globals.py
python3 bench/vs_tsgo/audit_globals.py --family same-file
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

The final source passes 4,232 checker tests, 101 program tests, 173 driver tests,
69 CLI tests, and 25 harness/report tests. The ReleaseFast binary's SHA-256 is
`7fd2c7e10e2471de753e474fca44abba8f00cfe4bf851284fe1b114653c756ce`.
All eighteen positive workloads still validate. With the stronger gates, Home
passes sixteen workload admissions and fails both graphs; both TypeScript
baselines pass all eighteen. The frozen predicate source hashes are unchanged.

[#480](https://github.com/home-lang/home/issues/480) remains open for real
cross-file declaration/type ownership; a same-file fix does not solve it.
[#487](https://github.com/home-lang/home/issues/487) tracks graph readmission
and broader coverage. Promise result erasure and the valid generic async
projection failure remain reproducible under
[#475](https://github.com/home-lang/home/issues/475) and
[#476](https://github.com/home-lang/home/issues/476), with the diagnostic-text
gap in [#478](https://github.com/home-lang/home/issues/478). Async remains untimed
under [#473](https://github.com/home-lang/home/issues/473).

### Checked-type ownership and assertion returns (untimed)

Commit [`091f15129`](https://github.com/home-lang/home/commit/091f1512954bf216b86556d9f892b6e59134e752)
moves core declaration/signature metadata into the stable `Compilation` result
before destroying its temporary checker. This fixes the retained relation
engine borrowing a destroyed rest-signature table. The transfer moves existing
maps, rather than cloning type graphs, and rebinds the engine as part of the
same operation. Type IDs, string IDs, and declaration nodes still belong to the
source compilation; equal numeric IDs from separate files are not interchangeable.

Post-compilation tests exercise rest-tuple assignability in both directions,
incompatible parameters, generic constraints/defaults and return members,
optional arguments, explicit `this`, predicate metadata, overloads, source
nodes, and independent compilation lifetimes. These tests also exposed
[#489](https://github.com/home-lang/home/issues/489): assertion signatures were
incorrectly lowered as boolean guards. Commit
[`134a9102d`](https://github.com/home-lang/home/commit/134a9102d4e9f022035033bbec058e385405a0d6)
preserves `void` for assertions and `boolean` for ordinary guards in declaration,
function-type, and low-level type lowering. Identical parameter lists remain in
the tests, so the guard/assertion collision is exercised rather than avoided.

| Untimed assertion family, valid and invalid scripts/modules | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Function declarations | 4/4 | 4/4 | 4/4 |
| Function-type aliases | 4/4 | 4/4 | 4/4 |
| Interface methods | 4/4 | 4/4 | 4/4 |

These 36 shared CLI checks use identical strict/noEmit/noLib/skipLibCheck
projects and the minimal library. Invalid inputs must report two TS2322 errors:
using an assertion's result as boolean and assigning its signature to a
boolean-returning function. Removing only those two statements yields valid
controls. Before the fix, Home instead rejected the valid `void` result and
accepted the invalid boolean uses. The low-level tests additionally cover
`asserts value` without an `is` target.

The final functional source passes 4,236 checker tests, 175 driver tests,
101 program tests, 69 CLI tests, and 25 harness/report tests. All 72 earlier
generic-callback checks still pass. The local evidence directory is
`bench/vs_tsgo/results/type-ownership.DvClDP`; the ReleaseFast binary SHA-256 is
`2d1bd9e91307373ffe28b5f0af3f9efb11ea96039df3b2ad77c9540e60fee942`.

This was an ownership prerequisite, not completed cross-file type linkage.
At this checkpoint, [#488](https://github.com/home-lang/home/issues/488) remained
open for interpretation tables such as `NoInfer`, `this` markers,
readonly/pattern index metadata, and tuple/array origins. The following
checkpoint extends that ownership coverage. The global audit still has 14 Home failures out of 132
checks; Home still fails both imported-graph rejection gates. Sixteen workload
gates pass, but neither graph is readmitted and the other rows remain provisional.
No timing run or new speed claim was made under concurrent workstation load.
The published timings and frozen predicate sources are unchanged.

### Semantic metadata ownership and tuple admission (untimed)

Commit [`304fd5d06`](https://github.com/home-lang/home/commit/304fd5d0697ed8b2ee691bc80e4199413b0abb29),
the follow-up to [#488](https://github.com/home-lang/home/issues/488), retains
113 checked-metadata tables with the owning compilation. Structural type
payloads alone do not encode the following information:

| Retained category | Representative post-compilation coverage |
|---|---|
| Inference/context markers | `NoInfer<T>` targets and `ThisType<T>` receivers |
| Index signatures | Readonly flags, parameter/declaration names, template-pattern keys and values |
| Tuple/array interpretation | Origin flags, trailing rest elements, ordered symbolic spreads |
| Generator protocols | Yield, return, and next types |
| Nominal declarations | Class/enum origins, base links, visibility, abstract members, accessor writes, constructor overloads |
| Alias/signature provenance | Generic arguments, display names, predicates, overloads, and source-node IDs |

Allocator-owned maps and nested containers move intact. Six maps contain
borrowed leaf slices (display strings or concrete type arguments); capture
copies those leaves before any ownership changes, without copying type graphs
or retaining the diagnostic arena. Exhaustive allocation-failure injection
checks that a failed capture leaves the checker, empty destination, and relation
engine binding unchanged. Further tests read metadata after checker destruction
and after freeing the caller's source text. All IDs remain relative to the
owning HIR/interner: this does not implement foreign-ID remapping, module
resolution, declaration merging across files, or cycle/file-order handling.
Those remain under [#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487).

Commit [`cbc757dcc`](https://github.com/home-lang/home/commit/cbc757dcc)
([#492](https://github.com/home-lang/home/issues/492)) adds a permanent
rejection gate for the existing variadic-tuple workload. The independent audit
uses seven valid/invalid pairs, retaining the full workload and changing only
one appended statement at a time:

| Untimed tuple control, positive + negative | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Inferred concatenation result | 2/2 | 2/2 | 2/2 |
| Conditional head | 2/2 | 2/2 | 2/2 |
| Conditional tail | 2/2 | 2/2 | 2/2 |
| Captured spread | 2/2 | 2/2 | 2/2 |
| Consumed tuple result | 2/2 | 2/2 | 2/2 |
| Readonly element write | 2/2 | 2/2 | 2/2 |
| Out-of-bounds element | 2/2 | 2/2 | 2/2 |

All 42 controls pass both before and after the ownership change. The permanent
gate appends all seven invalid statements to a temporary copy and requires
exactly five TS2322 errors, one TS2493, and one TS2540, with compiler exit 1 or 2.
The original positive project must pass first. Schema 3 records this gate and
preserves the schema-2 graph gates; validation still precedes result-directory
creation, warmups, and all timing. Legacy tuple observations remain provisional,
not retroactively validated by this newer binary. The timed corpus is unchanged.

The final source passes 4,237 checker tests, 178 driver tests, 101 program tests,
69 CLI tests, and 29 benchmark-harness/report tests. The 36 assertion controls
still pass. All eighteen positive workloads pass; sixteen complete workload
gates pass and both graph gates fail. The global audit remains 44/44 for each
TypeScript baseline and 30/44 for Home (14 failures across 132 total checks).
Neither graph is readmitted. No new timings were collected under concurrent
workstation load.

Local evidence is retained in `bench/vs_tsgo/results/semantic-ownership.JD0NXP`.
The ReleaseFast binary SHA-256 is
`9e4957a5a17dab0ea15a7334ba09ac8044c6f2894101f180718ed190e314e99d`.
The unchanged tuple source SHA-256 is
`78105a6b28024f5ac1dd32cc81d3aa065a3a99a1972927e1880f0a28eec5324f`;
both frozen predicate source hashes also match the preceding checkpoint.

### Canonical type-graph transfer (untimed)

Commit [`e4c0a4caa`](https://github.com/home-lang/home/commit/e4c0a4caaf65c3a2177a66f7af65492e3ca0bbf3)
implements the payload-transfer primitive tracked in
[#494](https://github.com/home-lang/home/issues/494). It returns an owned
source-to-destination TypeId map, resolving structural dependencies iteratively
through the destination's canonical interner. A raw-copy prototype failed an
actual literal-assignability test because equal literals had different IDs;
the implementation now reuses canonical structural keys without changing the
relation engine. Declaration-scoped objects, type parameters, and enum literals
retain distinct identities across owners.

The caller supplies consistent string-content and declaration-owner mappings.
The transfer preserves all stored payload kinds, including shared/recursive
object and parameter edges, generic signature arguments, tuple flags,
conditional distribution, mapped modifiers, and enum identities. It validates
references and rejects unsupported unanchored cycles among immutable structural
keys instead of substituting `any`. Failure removes newly published intern keys
and enum entries before restoring payload-column lengths. Retained allocation
capacity and caller-owned string/provenance allocations are not rolled back.

Seven focused tests cover payloads after source destruction, overlapping IDs
from independent owners, real string/literal/signature relations, reuse of
fourteen existing structural keys, an 8,192-node forward dependency chain,
invalid mappings/references, and exhaustive allocation-failure rollback. The
focused runner passes 8/8 including its module test root.

Fault injection also exposed two initialization leaks, fixed in
[`99a8b7866`](https://github.com/home-lang/home/commit/99a8b7866b67a39c0c3c83b99cacda7ec5f237dc)
([#498](https://github.com/home-lang/home/issues/498)). `Pool.init` now cleans up
partially initialized columns; `Interner.init` releases its pool if initial
header reservation fails. Before-fix probes leaked 144 bytes on the first
failing column append and, with pool cleanup alone, 3,072 bytes in 21 allocations
on header-reservation failure. Both exhaustive initialization tests now pass.
These are ownership fixes, not measured speedups.

The full suites pass 4,246 checker tests, 178 driver tests, 101 program tests,
69 CLI tests, and 29 benchmark-harness/report tests. A fresh ReleaseFast binary
was checked against version-verified TS 6.0.3 and native TS 7.0.2:

| Untimed CLI audit | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Existing positive workloads | 18/18 | 18/18 | 18/18 |
| Variadic tuple controls | 14/14 | 14/14 | 14/14 |
| Assertion-return controls | 12/12 | 12/12 | 12/12 |
| Same-file global declarations | 24/24 | 24/24 | 24/24 |
| Cross-file global declarations | 20/20 | 20/20 | 6/20 |

Home still passes sixteen workload gates and fails both imported-graph gates;
the global audit still reports fourteen failures across 132 checks. The transfer
primitive is **not yet called by program checking**. It does not transfer the
113 checked-metadata tables, construct real HIR/source provenance, resolve
imports or global merges, handle module cycles, or invalidate owner-specific
caches. These are prerequisites to integration under
[#480](https://github.com/home-lang/home/issues/480) and graph readmission under
[#487](https://github.com/home-lang/home/issues/487). Neither graph is readmitted,
and the other timing rows remain provisional.

Local evidence is retained in `bench/vs_tsgo/results/type-transfer.FHPXSf`.
The final ReleaseFast binary SHA-256 is
`860760ccee9bd0935b3371da534756bf148c733bce540d51c86714e96dce962c`.
The tuple and both predicate source hashes match the previous checkpoint.
No timings were collected during concurrent workstation activity; the published
timing snapshot is unchanged. Reproduce the focused checks and permanent
admission audit with:

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='type transfer'
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='initialization'
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
```

The last command intentionally exits nonzero while the fourteen known Home
failures remain; they are not skipped or waived.

### Owner-scoped semantic transfer and imported-owner audit (untimed)

Commit [`778597026`](https://github.com/home-lang/home/commit/7785970261d70ff50b2be710d09d78015a44a3c7)
adds a deep, owner-scoped clone of all 113 retained checked-metadata tables
([#500](https://github.com/home-lang/home/issues/500)). An exhaustive schema
distinguishes type, string, and declaration IDs from parameter positions,
argument counts, flags, and source-relative virtual-section offsets. Adding an
unclassified table or nested record field fails compilation. Slices, display
text, and nested containers are independently owned. Invalid references,
unmapped names/nodes, and many-to-one keys within a table fail explicitly;
the source stays unchanged and no partial result is returned. Callback
allocations and the previously transferred type pool remain caller-owned.

Each result must stay associated with its source owner. Canonical structural
signatures do not uniquely identify declaration-specific predicates or source
locations. Commit
[`84dc71ca5`](https://github.com/home-lang/home/commit/84dc71ca522ed33d0262aa5c3dbba25956eae960)
tests two independently compiled modules with same-named declarations against
one destination type interner. Both guards reuse an existing canonical
`(unknown) => boolean` signature, while their string/number predicates and real
source-owner/node references remain separate. It also checks constrained
generics, private class and enum origins, `NoInfer`, readonly pattern indexes,
symbolic tuple layouts, and positive/negative rest-signature assignability
after destroying the source semantic tables. Source HIR and text stay alive
for provenance lookup; registry handles are not fabricated local HIR nodes.

The focused checker runner passes 4/4 (three tests plus its module root),
including every table populated, exhaustive allocation-failure injection,
source destruction, mixed key fields, sentinel preservation, invalid mappings,
collisions, and successful retry. The full checker suite passes 4,249/4,249,
driver 179/179, program 101/101, CLI 69/69, and benchmark-harness/report 33/33
tests.

Commit [`50ff4add4`](https://github.com/home-lang/home/commit/50ff4add4552ef64e01826f00a59e9bd1c5f78ca)
adds the permanent [imported-owner audit](https://github.com/home-lang/home/blob/50ff4add4552ef64e01826f00a59e9bd1c5f78ca/bench/vs_tsgo/audit_owners.py).
Each family imports same-named declarations from two real modules. Valid and
invalid projects share every declaration and compiler option; only invalid
statements are appended to the negative app. Each pair runs with the app
explicitly listed before and after both declaration files. All three compilers
receive identical strict/noEmit/noLib/skipLibCheck inputs and the same minimal
library. Success requires acceptance of valid inputs or the exact expected
diagnostic-code multiset and failure exit status, not merely any rejection.

| Imported-owner audit: valid + invalid, both root orders | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Constrained generic results and arguments | 4/4 | 4/4 | 2/4 |
| Distinct predicates on same-shaped signatures | 4/4 | 4/4 | 0/4 |
| Private class declaration origins | 4/4 | 4/4 | 2/4 |
| Ordered rest-tuple arguments | 4/4 | 4/4 | 2/4 |
| Readonly and mutable imported members | 4/4 | 4/4 | 2/4 |

Both the preceding `e4c0a4caa` binary and the fresh ReleaseFast audit find twelve
Home failures across sixty checks. Generic, rest, and readonly invalid programs
are incorrectly accepted. Valid predicate narrowing is rejected; invalid
predicate cases have extra/wrong diagnostics because values remain `unknown`.
Private-class assignments are rejected with TS2741 rather than the required
TS2322, so those failures are diagnostic mismatches, not false acceptance.
Both root orders produce the same outcomes. These are untimed correctness
controls, not additional speed rows or evidence that program integration works.

Neither transfer operation is called by program checking yet. The next step
must connect real source-aware declaration lookup and owner-scoped semantic
records to typed resolution, including merging, cycles, and invalidation under
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487). Blindly merging these
records or treating their provenance handles as local HIR nodes would be
incorrect. Publication must also coordinate the separately transactional type
payload transfer and metadata clone; a failed metadata clone does not roll back
the caller's previously transferred type pool. The broader owner audit remains
part of readmission evidence; known failures are not waived. Historical timings
remain unchanged.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='checked transfer'
./pantry/.bin/zig build test -Dfilter=ts_driver
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

## Program-wide name identity and bound global ownership (untimed)

Every prepared `Program` source now retains a reference-counted handle to one
sharded name store. Per-file HIR, binder symbols, declarations, NodeIds, and
TypeIds remain separate: equal StringIds are meaningful across the program,
but foreign local IDs are never interpreted through another source. Serial,
parallel, streaming, bind-only, incremental, and cached-emission paths retain
the store explicitly, and recompilation preserves existing name IDs.

Program-level global discovery now indexes actual root binder maps by name and
value/type/namespace meaning. Each entry retains its source owner and symbol,
including merged declaration NodeIds. Presence-only checker inputs are
projections of that index, replacing raw scans which only recognized the first
plain `var` declarator and mistook comment text for module syntax. The binder
hoists block and loop `var` declarations to the nearest variable environment
while keeping `let` and `const` lexical. CommonJS export discovery also reuses
the prepared syntax owner instead of compiling every source a second time.

The permanent untimed audit uses six visible declaration shapes (plain,
comma-separated, destructured, block-hoisted, comment-adjacent, and escaped)
and five isolation shapes (inline external module, function, namespace,
lexical block, and lexical loop). Every case runs with its declaration root
both before and after the consumer. Visible declarations have positive,
missing-name, and wrong-type controls; isolated declarations have positive and
negative controls. Negative projects only append an invalid use, exact
diagnostic-code multisets are required, and all compilers receive identical
projects and configurations.

| Bound-global ownership audit | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Visible declaration and rejection controls | 36/36 | 36/36 | 4/36 | 24/36 |
| Module and lexical isolation controls | 20/20 | 20/20 | 18/20 | 20/20 |
| Total | 56/56 | 56/56 | 22/56 | 44/56 |

All twelve remaining Home failures are deliberately retained wrong-type
controls: the declaration name is visible, but its foreign TypeId is not yet
linked. This result therefore does not readmit either graph workload or change
any timing claim. Typed global/import resolution remains tracked in
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487); shared identity and bound
ownership are tracked in
[#515](https://github.com/home-lang/home/issues/515).

Implementation commits
[`ac52b6203`](https://github.com/home-lang/home/commit/ac52b6203),
[`0a296c1de`](https://github.com/home-lang/home/commit/0a296c1de), and
[`347693b72`](https://github.com/home-lang/home/commit/347693b72) establish the
shared store, correct variable-environment binding, and add the source-owned
declaration index respectively. The audit itself landed in
[`3f1c34ee9`](https://github.com/home-lang/home/commit/3f1c34ee9).

The interner suite passes 16/16, binder 21/21, driver 187/187, and program
109/109, including allocation-failure cleanup, concurrent retention,
independent lifetimes, every execution mode, incremental recompilation, and
module isolation. The benchmark harness has 38 structural tests. Raw evidence
is retained in `bench/vs_tsgo/results/program-identities.4udJSv`. The
pre-change ReleaseFast binary is `callable-unions.2pCgVc/home-v5`, SHA-256
`462eaf0f83137f05205ac50705c5b4878c0e24f18a7b69fcb1804dc1a03a30dc`.
The final ReleaseFast binary is `program-identities.4udJSv/home-final`,
SHA-256
`0b7289905e110f79611a967097cab671ef1726e5ae06a60cfaf7bb8a26b604ea`.

```sh
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_bound_globals.py
```

Local evidence is retained in `bench/vs_tsgo/results/checked-transfer.IO4A4Q`.
The final ReleaseFast binary SHA-256 is
`4ad8003e751e1471db6f7ea855c3bf8a3822063e89ddb793b85d3714efe93393`.
The fresh release also passes all 42 tuple controls and 36 assertion controls;
the global audit remains 30/44 for Home versus 44/44 for each TypeScript baseline
(fourteen failures across 132 total checks). All eighteen existing positive
workloads pass; Home passes sixteen workload gates and still fails both graph
gates. Neither graph is readmitted, and passing sixteen gates does not establish
sixteen equivalent semantic workloads. The tuple and both predicate source
hashes are unchanged. No timing run was made during concurrent workstation
activity.

### Atomic owner publication and source provenance (untimed)

Commit [`9d8be00d7`](https://github.com/home-lang/home/commit/9d8be00d7b1f61f487f559c863ce7cbc826e0d09)
adds a prepare/commit boundary to payload transfer. A pending transfer is
exclusively owned and cancelled on destruction unless committed. The combined
checked-transfer operation clones the complete semantic record before committing
payloads. Failure therefore restores the destination's original payload-column
lengths, intern keys, and enum entries, including when failure occurs only after
the entire payload graph has been prepared. Previously existing keys remain
valid. Retained allocation capacity is still owned by the destination.

Commit [`202f24b9a`](https://github.com/home-lang/home/commit/202f24b9ae2a56cabdae311533fd603bcb596ce5)
adds the production source-owner registry and replaces the earlier test-only
provenance mapper in the independently compiled owner regression. An owner
borrows immutable HIR, source text, strings, types, and checked metadata. Every
registration denotes a distinct owner/revision even when its path or memory
address is reused. Declaration handles resolve to the actual source owner,
node, span, path, and text. Unregistering the owner before destroying its
storage invalidates old handles; replacement sources cannot inherit those IDs.

Registry import coordinates declaration mappings with the combined
payload/semantic transaction. Failed imports remove newly created declaration
mappings while preserving earlier owners and handles. The caller's string
interner may retain unused strings and allocation capacity, but no failed type
or declaration mapping is published. A checked-owner view is available only
after semantic checking and metadata capture complete: bind-only results are
rejected. Completed checking with diagnostics remains distinct from an
unchecked source; valid empty programs also produce checked-owner views.
Readiness records phase completion, not imported-type parity or benchmark
eligibility.

| Untimed regression | Verified coverage |
|---|---|
| Pending transfer lifecycle | Explicit cancellation, repeated cleanup, commit, prior canonical keys and enum entries |
| Combined publication | Exhaustive allocation failures across payload and semantic preparation; late invalid mappings/collisions; successful retry |
| Source provenance | Real HIR/text lookup, same-path replacement, invalid spans/nodes, and stale-owner rejection |
| Coordinated registry rollback | Existing mappings survive; newly prepared mappings and types disappear together on failure |
| Compiled owners | Distinct predicates on a shared canonical signature, generic constraints, nominal origins, readonly/index metadata, tuples, and rest relations |
| Readiness | Bind-only compilation cannot be published as checked; empty and diagnostic-bearing checked results are distinguished |

The focused transfer runner passes 14/14, including its module test root.
The full checker suite passes 4,252/4,252, driver 183/183, program 101/101,
CLI 69/69, and benchmark harness/report 33/33 tests. The source registry's
failure tests include errors after the object header has already created its
real declaration mapping.

This completes the publication/provenance prerequisite in
[#504](https://github.com/home-lang/home/issues/504), not source-aware program
resolution. The shared transfer pool must use one registry's declaration
handles for **all** declaration-bearing types, including the local owner;
owner-local HIR IDs and another registry's handles must not be mixed into it.
Handles are not local HIR indices. Program lookup still needs owner-aware
interpretation, declaration merging, module-cycle handling, and dependency
invalidation under [#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487). Unregistering a source
invalidates provenance; callers must also stop using its dependent semantic
records. The registry does not yet implement that program-wide invalidation.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker -Dts-checker-test-filter='transfer:'
./pantry/.bin/zig build test -Dfilter=ts_driver
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

Local evidence is retained in `bench/vs_tsgo/results/owner-publication.xWNTr8`.
The final ReleaseFast binary SHA-256 is
`6d6b278c9df4db5a67171436def69c720fbe4d91e3171e8221c6d9cb161f4134`.
Fresh CLI audits against version-verified TS 6.0.3 and native TS 7.0.2 retain
the preceding checkpoint's results: all 42 tuple and 36 assertion controls
pass; the global audit has fourteen Home failures (30/44 versus 44/44 for each
baseline), and the imported-owner audit has twelve (8/20 versus 20/20).
All eighteen positive workloads pass; Home passes sixteen workload gates and
fails both graph rejection gates. Passing those sixteen gates is not proof of
sixteen semantically equivalent workloads.
The tuple and both frozen predicate source hashes are unchanged.
No timing claim follows from these ownership tests; historical timings remain
unchanged, and neither graph is readmitted.

### Prepared program discovery and expanded global audit (untimed)

Commit [`4693c6277`](https://github.com/home-lang/home/commit/4693c6277)
separates source preparation (parse/bind) from one-shot checking and emit.
Preparation retains the original HIR, tokens, binder symbols, declaration-file
flag, syntactic-error flag, and JSX comma-recovery spans. The parser can be
destroyed before checking begins. Checked-owner publication still occurs only
after semantic checking and metadata capture; preparation alone is not a typed
source owner. Failed checking is deinitializable and must not be retried on the
partially checked object.

Commit [`83d145926`](https://github.com/home-lang/home/commit/83d145926)
uses that boundary in the program pipeline. Import/reference discovery performs
parse/bind only and skips semantic fact collection during discovery rounds.
After the graph stops expanding, checking reuses its bound sources against the
final program facts. Conformance no longer reparses/rebinds/checks the complete
graph a second time. Serial, parallel, and streaming paths share the per-file
lifecycle. Streaming reference checks also receive the final known-path list.
If a caller explicitly checked an incomplete graph before expanding it, those
semantic results are invalidated and rebuilt; unchanged repeated discovery
retains the checked owners. This is not dependency-aware incremental checking.

The driver suite passes 186/186, program 105/105, and CLI 69/69. Regressions
cover retained binder/token identity, emit/check idempotence, declaration-file
and parser-recovery state, multi-hop discovery, serial/parallel/streaming
results, zero-worker fallback, expansion invalidation, and allocation-failure
cleanup/retry. The conformance suite passes 1,417/1,417. The unchanged checker
test target was a cache hit; no fresh checker execution is claimed here.

A separate CLI probe lists only the minimal library and `app.ts` as roots:

```ts
// app.ts
/// <reference path="./bridge.d.ts" />
globalThis.lateValue;
// bridge.d.ts
/// <reference path="./definitions.d.ts" />
// definitions.d.ts
declare var lateValue: number;
```

These are three separate source files, not concatenated input. Every compiler
uses the same strict/noEmit/noLib project and minimal library. Two invalid
variants append statements to the unchanged app: one adds `missingValue; const
bad: string = 1;`, and the other adds `const wrong: string =
globalThis.lateValue;`. Diagnostic multisets and exit status must match.

| Untimed transitive-reference probe | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---|---|---|---|
| Valid project | Pass | Pass | False TS6053 × 2 and TS7017 | Pass |
| Invalid local code | TS2304 + TS2322 | TS2304 + TS2322 | Expected errors plus false reference/global errors | TS2304 + TS2322 |
| Invalid global property assignment | TS2322 | TS2322 | Incorrect reference/global diagnostics | Incorrectly accepted |

This proves the scheduling correction, **not** typed-global parity. The earlier
binary is the preceding checkpoint's `home-final` (SHA-256 `6d6b278c9df4db5a67171436def69c720fbe4d91e3171e8221c6d9cb161f4134`).
The before/after probe has twelve checks including that older Home binary:
four fail, three in the older Home and one in the new Home.

Commits [`bebe678de`](https://github.com/home-lang/home/commit/bebe678de) and
[`445422c60`](https://github.com/home-lang/home/commit/445422c60) extend the
permanent global audit with sibling ambient `let` and `const` bindings and
typed `globalThis` reads, each positive/negative and with both
declaration-before/after-app orders. The lexical cases report false TS2304;
the invalid `globalThis` assignments are accepted. Neither failure is waived.
The original 44 controls retain their prior results; the larger denominator
reflects twelve added controls, not a timing or correctness regression.

| Fresh untimed audit | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Expanded globals | 56/56 | 56/56 | 32/56 |
| Imported owners | 20/20 | 20/20 | 8/20 |
| Tuple controls | 14/14 | 14/14 | 14/14 |
| Assertion controls | 12/12 | 12/12 | 12/12 |

All eighteen positive benchmark workloads pass. Home still fails both graph
rejection gates and passes the other sixteen gates; that is not evidence of
sixteen semantically equivalent workloads. Both graph timing claims remain
ineligible. The tuple and both predicate corpus hashes are unchanged, and no
timings were collected during concurrent workstation activity.

```sh
./pantry/.bin/zig build test -Dfilter=ts_driver
./pantry/.bin/zig build test -Dfilter=ts_program
./pantry/.bin/zig build test -Dfilter=ts_conformance
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

The harness suite passes 33/33. Local evidence, including the independent
discovery probe and raw diagnostics, is retained in
`bench/vs_tsgo/results/prepared-program.Wx2zap`. The fresh ReleaseFast binary
SHA-256 is `a3eddac96fe1b07d7876defc63a2cda06b9f13210b333e8dc57e2b38e8a0ea12`.
This addresses the scheduling/reuse work in
[#505](https://github.com/home-lang/home/issues/505). Actual owner-aware global
and import type resolution, declaration merging, and module-cycle semantics
remain open in [#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487), under the performance
tracker [#416](https://github.com/home-lang/home/issues/416).

### Callable identity and scoped inference (untimed)

The audit added in [`d4e63ff6c`](https://github.com/home-lang/home/commit/d4e63ff6c)
exposes a declaration-identity bug tracked in
[#507](https://github.com/home-lang/home/issues/507): signatures with equal
parameter and return types shared a TypeId even though their predicates,
optional/rest parameters, generic binders, and declaration metadata differed.
For example, the predicate and ordinary boolean methods below must not share
narrowing behavior:

```ts
interface Guards {
  number(value: unknown): value is number;
  plain(value: unknown): boolean;
}
declare const guards: Guards;
declare let value: unknown;
const plain = guards.plain;
if (plain(value)) { const bad: number = value; } // TS2322
```

The earlier Home binary accepts that invalid assignment; both pinned TS
compilers reject it. The permanent audit has seven families: predicate aliases,
direct calls, wrapper objects, predicate assignments, rest parameters, optional
parameters, and generic arity. Every family includes valid/invalid pairs in
both declaration orders and script/module scopes: 56 cases per compiler.
Only invalid statements are appended to each positive project. All compilers
receive identical files, flags, and the minimal library; exit status and exact
diagnostic-code multisets must agree. No failures are skipped and no timings
are taken by this audit.

Commit [`15f050f23`](https://github.com/home-lang/home/commit/15f050f23)
changes callable creation to allocate distinct identities without an erased-shape
hash entry. Structural relations still decide compatibility. Creation reserves
all pool columns before publishing lengths, and retains offsets when its input
parameters borrow the same pool. Type transfer preserves distinct imported
callables while still deduplicating immutable keys.

Related checker corrections explicitly preserve predicates/generic metadata
during inference, prevent local generic callback binders from becoming outer
inference candidates, retain identity for unaffected substitutions, and use
structural subtype reduction for conditional objects with callable members.
Argument context snapshots remain valid while checking earlier arguments grows
the signature pool. These replace dependencies on accidental TypeId sharing;
they do not add name-specific or benchmark-specific exceptions.

| Callable family | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Predicate alias | 8/8 | 8/8 | 4/8 | 8/8 |
| Predicate direct call | 8/8 | 8/8 | 4/8 | 8/8 |
| Predicate wrapper | 8/8 | 8/8 | 4/8 | 8/8 |
| Predicate assignment | 8/8 | 8/8 | 4/8 | 8/8 |
| Rest parameters | 8/8 | 8/8 | 4/8 | 8/8 |
| Optional parameters | 8/8 | 8/8 | 2/8 | 8/8 |
| Generic arity | 8/8 | 8/8 | 4/8 | 8/8 |
| Total | 56/56 | 56/56 | 26/56 | 56/56 |

The fresh release also passes all 14 tuple controls and 12 assertion controls.
The global and imported-owner audits remain at 32/56 and 8/20 respectively;
their individual pass/fail results and diagnostic-code multisets are unchanged.
All eighteen positive benchmark workloads pass, but Home still accepts the
invalid imported-property controls for both module graphs. Both graph timing
claims remain ineligible. Passing the other sixteen admission gates does not
establish semantic equivalence for all their language features.

The checker suite passes 4,257/4,257, conformance 1,417/1,417, driver 186/186,
program 105/105, CLI 69/69, and harness tests 35/35. Tests cover distinct callable identities, pool growth,
allocation-failure publication, transfer relations and metadata, unaffected
substitution, hidden predicate targets, and scoped callback binders. The two
existing overload-context fixtures also match both pinned compilers' complete
diagnostic-code multisets in a separate CLI probe (six checks, no failures).
The transitive-reference probe remains at 2/3 for Home and 3/3 for each TS
baseline. Repository-wide Pickier aborted at its 100,000-file safety limit
(177,405 files discovered); targeted lint of the changed files passes with
one pre-existing README link-fragment warning.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker
./pantry/.bin/zig build test -Dfilter=ts_driver
./pantry/.bin/zig build test -Dfilter=ts_program
./pantry/.bin/zig build test -Dfilter=ts_conformance
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_callables.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

Local raw evidence is retained in
`bench/vs_tsgo/results/signature-identity.6jiDkG`. The before binary SHA-256 is
`a3eddac96fe1b07d7876defc63a2cda06b9f13210b333e8dc57e2b38e8a0ea12`;
the fresh ReleaseFast binary is
`d7ecf960b76ef1f61b3e9acf4ebb97cad70fc3d087db20c5a5cdce03d82e6ffc`.
Both installed baseline versions were verified exactly before the audits.
Predicate and tuple corpus hashes are unchanged. No new timings were collected,
so this checkpoint makes no speedup or universal-leadership claim. Actual
cross-file type resolution remains open in
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487).

### Callable union predicates and receivers (untimed)

The follow-up audit in
[`79d9ce2ca`](https://github.com/home-lang/home/commit/79d9ce2ca), tracked in
[#511](https://github.com/home-lang/home/issues/511), tests the semantic work
required when choosing between callable values. Distinct callable identities
alone do not prevent an erased-shape subtype check from discarding a branch:

```ts
declare function guard(value: unknown): value is number;
declare function plain(value: unknown): boolean;
declare let value: unknown;
const selected = [guard, plain];
if (selected[0](value)) { const bad: number = value; } // TS2322
```

The previous Home binary accepts this invalid narrowing. Conversely, unions
of genuine guards lose their shared narrowing information in several paths,
rejecting valid uses. A callable union also requires a receiver satisfying
every possible branch, rather than any one branch as for an overload set.

The permanent audit contains four families, each tested with declaration and
branch order varied independently, arrays and conditional expressions, bare
callables and object wrappers, script/module scope, and valid/invalid pairs.
That is 64 cases per family and 256 per compiler. Negative projects only append
an invalid use to the corresponding positive project. Files, compiler flags,
and minimal library are identical for all three compilers. Exact installed
versions, exit statuses, and diagnostic-code multisets are checked; no failures
are waived. These are untimed controls, not new timed workloads.

| Callable union family | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Predicate plus ordinary boolean | 64/64 | 64/64 | 60/64 | 64/64 |
| Different predicate targets | 64/64 | 64/64 | 12/64 | 64/64 |
| Same predicate target | 64/64 | 64/64 | 16/64 | 64/64 |
| Explicit receiver requirements | 64/64 | 64/64 | 32/64 | 64/64 |
| Total | 256/256 | 256/256 | 120/256 | 256/256 |

Commit [`7d16f7ab8`](https://github.com/home-lang/home/commit/7d16f7ab8)
consults predicate and receiver metadata before reducing
callable unions. Resolved signatures combine predicate targets only when
every branch promises a compatible predicate kind and argument position.
Combined targets have no fabricated source annotation. Receiver checking uses
the union's combined signatures, which intersect receiver requirements; the
zero-argument and two-branch restrictions are removed. A previous receiver
substitution based on accidentally shared signature identity is also removed.
Arity is captured before interning can invalidate borrowed parameter storage,
and union-member traversal retains its own stable IDs. Matching retains the
selected common parameter contract instead of substituting a longer branch's
parameters, preserving required/minimum and maximum argument counts. Result
overloads are deduplicated by their complete parameter/receiver contracts,
not by the partial compatibility used to find cross-branch candidates.

The two baseline versions agree on every audit case. A separate diagnostic
probe found that a direct, non-union receiver missing one required property
produces TS2684 in TS 6 and TS2741 in native TS 7. The existing native-style
elaboration is retained; this disagreement is not hidden by relaxing the audit.

The final release also passes all 56 callable-identity controls, 14 tuple
controls and 12 assertion controls. Four additional checker-fixture comparisons
cover five-way union arity, valid optional/rest calls, conditional minimum
arity, and three-way predicate/receiver composition: all twelve compiler/fixture
checks match the pinned baselines. All eighteen positive workloads pass and
sixteen rejection gates pass. The two graph gates still fail; global controls
remain 32/56, imported-owner controls 8/20, and transitive-reference checks 2/3
for Home. Those gaps are not waived by the new callable results.

The full checker suite passes 4,261/4,261, including the original arity
regressions unchanged and the new predicate/receiver tests. Conformance passes
1,417/1,417. Driver passes
186/186, program 105/105, CLI 69/69, and harness 37/37. Repository-wide Pickier
aborts at its 100,000-file safety limit (177,457 files discovered); targeted
lint has no errors and one pre-existing README fragment warning.

Raw evidence is retained in `bench/vs_tsgo/results/callable-unions.2pCgVc`;
final compiler verification logs use the `-v5.log` suffix. The frozen pre-change binary
is `signature-identity.6jiDkG/home-final`, SHA-256
`d7ecf960b76ef1f61b3e9acf4ebb97cad70fc3d087db20c5a5cdce03d82e6ffc`.
The final ReleaseFast binary is `callable-unions.2pCgVc/home-v5`, SHA-256
`462eaf0f83137f05205ac50705c5b4878c0e24f18a7b69fcb1804dc1a03a30dc`.
Earlier candidate runs, including failed regression runs, are retained too.
Predicate and tuple workload hashes are unchanged. No new timings were
collected and both graph speed claims remain ineligible. Actual typed global
and imported declaration linkage remains open in
[#480](https://github.com/home-lang/home/issues/480) and
[#487](https://github.com/home-lang/home/issues/487).

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker
./pantry/.bin/zig build test -Dfilter=ts_conformance
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_callable_unions.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_callables.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

### Checked-owner lifetime and typed-global consumer contract (untimed)

The next checkpoint for [#480](https://github.com/home-lang/home/issues/480)
and [#487](https://github.com/home-lang/home/issues/487) establishes source
lifetime and checker lookup boundaries. Commit
[`33d8c15c5`](https://github.com/home-lang/home/commit/33d8c15c5) registers each
checked program-file revision with its source-owner registry and tombstones
that identity before replacement or destruction. Parallel publication is
serialized; incremental recompilation retains unaffected owners and assigns
fresh identities to replacements. Commit
[`76d6a8b2d`](https://github.com/home-lang/home/commit/76d6a8b2d) leaves scanner
recovery results without checked type storage unregistered, instead of
asserting that every diagnostic-bearing result has a typed source view.

Commit [`a142705f1`](https://github.com/home-lang/home/commit/a142705f1)
lets the checker accept explicit value/type bindings already relocated into
its receiving type pool and string keyspace. Local and forward declarations
take precedence. A separate property flag distinguishes global `var`-style
bindings from lexical bindings for dotted, bracketed, and indexed-`typeof`
access through `globalThis`; local bindings named `globalThis` still shadow
the global object. Focused tests cover primitive and structural object types,
call signatures, wrong assignments, missing members, invalid arguments,
non-generic type arguments, and lexical isolation.

This is a consumer contract, **not automatic cross-file type transfer**.
Program compilation still supplies presence-only names. Publishing real
bindings requires owner-aware declaration and semantic metadata, including
generic parameters, predicates, nominal identity, declaration merging, and
resolution independent of source order and cycles. The contract does not
authorize foreign local node IDs or incomplete metadata to be treated as local.

The unchanged audits were rerun against the frozen ReleaseFast binary and
exact installed baselines. Each compiler receives the same files and options;
valid cases must succeed silently, and invalid cases must match the expected
diagnostic-code multiset. Failures remain visible:

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home |
|---|---:|---:|---:|
| Global declaration controls | 56/56 | 56/56 | 32/56 |
| Bound-global discovery controls | 56/56 | 56/56 | 44/56 |
| Imported-owner controls | 20/20 | 20/20 | 8/20 |
| Import/re-export graph admission | 2/2 | 2/2 | 0/2 |

These results are unchanged from the prior checkpoint. Both graph projects
still accept invalid imported-property uses in Home, so neither is readmitted
for timing. The full admission check passes 16/18 workloads, with only those
two failures. No new timings were collected and no speedup is claimed.

The full checker suite passes 4,264/4,264, conformance 1,417/1,417,
program 110/110, driver 187/187, and harness 38/38. Zig formatting checks pass.
Targeted Pickier has no errors
and one pre-existing README fragment warning.

Raw logs and the frozen binary are retained locally in
`bench/vs_tsgo/results/global-consumer.xZ8NXj`. The final binary SHA-256 is
`f401735aa016d571c2aa4def48f47f4ff435a100af98c3d37c5d61afab392f09`.
The installed compilers report `Version 6.0.3` and `Version 7.0.2`; the old
`7.0.0-dev.20260707.2` version is explicitly rejected by harness tests.
Native TS 7 is one baseline, not separate `tsc 7` and `tsgo` competitors.

```sh
./pantry/.bin/zig build test -Dfilter=ts_checker
./pantry/.bin/zig build test -Dfilter=ts_program
./pantry/.bin/zig build test -Dfilter=ts_driver
./pantry/.bin/zig build test -Dfilter=ts_conformance
./pantry/.bin/zig build home-tsc -Doptimize=ReleaseFast
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_bound_globals.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
```

### Re-export discovery and declaration origins (untimed)

Issue [#520](https://github.com/home-lang/home/issues/520) isolates two
prerequisites for the typed graph work in
[#487](https://github.com/home-lang/home/issues/487): loading the complete
static dependency graph and recognizing the actual declaration behind an
export. These controls are not additional timed workloads.

The discovery audit has 28 cases: imports, named/star/namespace/type-only
re-exports, cycles, and diamonds, each tested with entry-only and all-files
roots. A negative case only appends a wrong local assignment in the leaf.
This detects an omitted source file without depending on imported type
inference. Pre-change Home passes 13/28; both pinned TypeScript baselines
pass 28/28. Commit
[`d440dbee6`](https://github.com/home-lang/home/commit/d440dbee6) loads static
re-export targets and rebuilds unique, current dependency edges. Program
tests also check repeated resolution, source replacement, and include
provenance.

The origin audit has 32 paired cases. It accepts two paths to the same
declaration while retaining genuine TS2308 conflicts and TS2305 missing-name
errors. It also checks default-import aliases, type-only function identity,
and runtime rejection through direct, named-barrel, and star-barrel aliases.
Local parameters that shadow an import remain usable. Both baselines pass
32/32; pre-change Home passes 4/32. Every compiler receives identical source
files, roots, and strict/noEmit/noLib/skipLibCheck options. Positive cases
must succeed silently; negative cases must match the diagnostic-code
multiset, not merely exit unsuccessfully.

The final ReleaseFast binary passes both new audits:

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Re-export discovery controls | 28/28 | 28/28 | 13/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 4/32 | 32/32 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The unchanged global, bound-global, and imported-owner audits remain
32/56, 44/56, and 8/20 for Home; both TypeScript baselines pass every case.
Full workload admission remains 16/18 for Home and 18/18 for each baseline,
with only the two original imported graph failures. No new timing run was
started, and no workload or negative control was removed to improve the result.

Commit [`2e1f795f9`](https://github.com/home-lang/home/commit/2e1f795f9)
implements the origin resolver and its checker/CLI integration. It uses a
visited worklist over source paths, names, lookup
mode, and value visibility. It follows aliases and cycles in the declaration's
own bound source, with a 96-module-chain regression test. Same-origin equality
requires actual overlapping declaration meanings; missing, incomplete, or
ambiguous resolutions cannot prove equality. The CLI retains immutable bound
source views across origin queries. Type-only paths retain symbol identity
for `typeof`, while recording whether the runtime restriction originated at
`import type` (TS1361) or `export type` (TS1362). Restriction positions retain
their source path, rather than becoming fabricated local node IDs.

This is **not automatic cross-file checked-type transfer**. The existing
legacy export-fact/name enumeration paths still have separate recursion
limits; the worklist test does not establish unlimited resolution throughout
the CLI. Generic parameters, predicates, nominal identity, and declaration
merging still require source-owned semantic linkage. The original graph
negative controls remain mandatory before either graph timing is eligible.

Raw evidence is retained in
`bench/vs_tsgo/results/reexport-discovery.rFhIvz`, including pre-change,
intermediate, failed, and superseded runs. `audit-before.log` is the discovery
baseline; `origins-before-final.log` is the final 32-case origin baseline.
The frozen pre-change binary is `global-consumer.xZ8NXj/home-final`, SHA-256
`f401735aa016d571c2aa4def48f47f4ff435a100af98c3d37c5d61afab392f09`.
The final binary is `reexport-discovery.rFhIvz/home-final`, SHA-256
`bff8e072e39c79f0d44e360b0b36ed5b984fd71183debb8e8736efa1aa6e6e3c`.
Its successful build log is `release-v4.log`; final audit logs use the
`-final.log` suffix. The original imported graph negatives are still accepted
without diagnostics by Home, so neither graph is readmitted for timing.
Runs marked TERM were stopped after source revisions and are not counted as
successful final verification. No new timings are reported here.

The final checker suite passes 4,266/4,266, conformance 1,417/1,417,
Program 117/117, driver 187/187, CLI 69/69, and the benchmark harness 41/41.
Zig formatting checks pass. Targeted Pickier reports no errors
and one pre-existing README fragment warning.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_graph_discovery.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_export_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported nominal identity without synthetic properties (untimed)

Tracked in [#521](https://github.com/home-lang/home/issues/521), under
[#487](https://github.com/home-lang/home/issues/487) and
[#416](https://github.com/home-lang/home/issues/416). The installed baseline
binaries were verified again as `Version 6.0.3` and `Version 7.0.2`.
The harness rejects the superseded native dev build; native TS 7 and `tsgo`
are one competitor, not two separate compiler results.

Audit commits [`ab691caf7`](https://github.com/home-lang/home/commit/ab691caf7)
and [`e40a4d546`](https://github.com/home-lang/home/commit/e40a4d546) retain the
failing controls and enforce fairness. The implementation is
[`4ae69562e`](https://github.com/home-lang/home/commit/4ae69562e).

Home previously added a required `__home_class_origin_...` property to imported
classes with non-public members. That implementation detail leaked into missing
property diagnostics (TS2741). The checker now attaches source-qualified origin
metadata to the real non-public members, without creating a property. Recursive
identity and assignability checks compare that metadata, including nested
objects, arrays, signatures, and intersections. Generic substitution preserves
it, and type transfer relocates its string ID independently of HIR node IDs.
The legacy source-path/module/class key is length-prefixed to prevent delimiter
collisions. This does not replace the legacy class projection with complete
source-owned checked declarations.

The new audit has 52 controls: 13 families, each with positive and appended-only
negative variants, checked with the app before and after declaration roots.
All compilers receive identical files, roots, and strict/noEmit/noLib/skipLibCheck
options. Successful controls must be silent; rejection controls must match the
exact diagnostic-code multiset. No failure is skipped or relabeled as a pass.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Imported nominal-identity controls | 52/52 | 52/52 | 30/52 | 36/52 |
| Existing imported-owner controls | 20/20 | 20/20 | 8/20 | 10/20 |
| Re-export discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global declaration controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Bound-global controls | 56/56 | 56/56 | 44/56 | 44/56 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The six newly passing nominal controls cover direct private/protected identity
and a public structural object assigned to a private class. The existing nested
object, array, function, and public-structural controls remain passing. Remaining
failures cover static-private imports (2 controls), generic arguments (2),
re-exported class aliases (2), private `keyof` (2), and private/protected inheritance
(8). Static member metadata is preserved when supplied, but Program's class
projection still omits the static-private declarations exercised here. Positive
inheritance failures are counted, not hidden by the corresponding negative case.

Full workload admission remains 16/18 for Home and 18/18 for each baseline.
Both original imported graphs still accept invalid uses and remain ineligible
for timing. No new performance measurement or speed claim is made. The new
member metadata has not yet been evaluated in a fresh timing/memory comparison.

The frozen pre-change binary is `reexport-discovery.rFhIvz/home-final`, SHA-256
`bff8e072e39c79f0d44e360b0b36ed5b984fd71183debb8e8736efa1aa6e6e3c`.
Evidence for this checkpoint is in `bench/vs_tsgo/results/nominal-origins.doZaNi`:
`audit-before-expanded.log` and `audit-final.log` use all 52 controls;
`audit-before.log` retains the initial 48-case run before static-private controls
were added. The final binary is `home-final`, SHA-256
`3cc741571c00fa3682fb3b4c4931273b0f57a910f12a61c022112ed780f7a245`;
its build log is `release.log`. Audit source SHA-256:
`98dcd584f5dc651d19c80fe28cd538e34b0bb3de176af87be067e64dbd400ea1`.

The checker suite passes 4,270/4,270, conformance 1,417/1,417, driver 187/187,
Program 117/117, CLI 69/69, focused origin tests 5/5 (including the test root),
and the benchmark harness 44/44. Fresh callable-identity and callable-union
audits remain 56/56 and 256/256 for all three compilers. Zig formatting checks
pass; targeted Pickier reports zero errors and the pre-existing README
fragment warning.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_nominal_origins.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_owners.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Bound class declarations and export aliases (untimed)

Tracked in [#522](https://github.com/home-lang/home/issues/522), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416). All runs below verify the
installed compilers as TS **6.0.3** and native TS **7.0.2**. The old native
`7.0.0-dev.20260707.2` build is rejected, not treated as another competitor.

Audit commits [`79f43d107`](https://github.com/home-lang/home/commit/79f43d107)
and [`cce32867b`](https://github.com/home-lang/home/commit/cce32867b) define 52
controls across 13 families. Each has a valid program and an appended-only
negative variant, with identical inputs/options for all compilers and both app
root orders. Valid controls must be silent; invalid controls must match the
exact diagnostic-code multiset. Type-only aliases must preserve class identity
without permitting runtime construction.

Implementation commits
[`226da3863`](https://github.com/home-lang/home/commit/226da3863) and
[`b45b038e0`](https://github.com/home-lang/home/commit/b45b038e0) replace the
source-text class scanner with already-bound declaration traversal. Export
binding names/paths are separate from declaration names/paths/positions. Alias
queries and a visited star-export candidate worklist retain the actual owner
through renaming, defaults, cycles, and explicit shadows. Class fields use HIR
static/visibility flags; comments are not members and quoted keyword names are
ordinary public properties. Namespace declaration context is retained in HIR,
and `keyof` excludes non-public class members.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Bound-class export controls | 52/52 | 52/52 | 22/52 | 48/52 |
| Imported nominal-identity controls | 52/52 | 52/52 | 36/52 | 40/52 |
| Existing imported-owner controls | 20/20 | 20/20 | 10/20 | 10/20 |
| Re-export discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global declaration controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The four remaining class-export failures are negative static-member and
merged-namespace visibility uses, each in both root orders. The collected facts
are retained, but the consumer still falls back to `any` for these imported
values. The nominal audit still fails private-static identity (2 controls),
generic arguments (2), and private/protected inheritance (8). Alias identity
and private `keyof` now pass. Full workload admission remains 16/18 for Home
and 18/18 for each baseline; the two original graphs remain ineligible for timing.

This is not complete cross-file checked-type transfer. Complex member types,
method/constructor signatures, generic constraints, heritage, ambient class
export aliases, and computed names still need source-owned semantic linkage.
The existing relative module namespace-augmentation text collector remains a
separate legacy boundary. No new timings or speed/memory claims are made.

Raw evidence is in `bench/vs_tsgo/results/bound-classes.8s4Xq1`.
`bindings-before-type-only.log` and `bindings-v1.log` contain the final 52-case
before/after audit; earlier 40/44-case runs are retained but are not mixed into
the table. The frozen baseline is `nominal-origins.doZaNi/home-final`, SHA-256
`3cc741571c00fa3682fb3b4c4931273b0f57a910f12a61c022112ed780f7a245`.
The final ReleaseFast binary is `bound-classes.8s4Xq1/home-v1`, SHA-256
`7f71d18f3a1648032b346183267382573f02475b824f5db8c30e0cc463568bd2`;
its successful build log is `release-final.log`. Other audit logs use `-v1.log`.
Audit source SHA-256:
`97f9bdc75c50957c33e4139f05b66eb21750fad2fa51741a990b6525449ea6ea`.
Debug, failed, interrupted, and superseded runs remain separately labeled and
are not counted as final release verification.

The checker suite passes 4,271/4,271, conformance 1,417/1,417, Program 119/119,
driver 187/187, CLI 69/69, parser 897/897, HIR 12/12, and benchmark harness
47/47. Fresh bound-global controls remain 44/56 for Home and 56/56 for each
baseline. Callable-identity and callable-union controls remain 56/56 and 256/256
for all three compilers. Zig formatting checks pass.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_class_bindings.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_nominal_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported static values and module namespace consumers (untimed)

Tracked in [#523](https://github.com/home-lang/home/issues/523), following
[#522](https://github.com/home-lang/home/issues/522), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416). The harness verifies
TS **6.0.3** and native TS **7.0.2** before every run. Native TS 7 and `tsgo`
remain one competitor; the superseded dev build is rejected.

The main implementation is
[`cdcb60b41`](https://github.com/home-lang/home/commit/cdcb60b41).

Audit commits [`232961504`](https://github.com/home-lang/home/commit/232961504),
[`170613d01`](https://github.com/home-lang/home/commit/170613d01), and
[`89698128c`](https://github.com/home-lang/home/commit/89698128c) define the final
84 controls: 21 families, each with positive and appended-only negative variants
in both app root orders. All compilers receive identical files, roots, and
strict/noEmit/noLib/skipLibCheck options. Positive controls must be silent;
negative controls must match the exact diagnostic-code multiset.

The audit covers named/default imports, aliases, module namespaces, captured
namespaces and constructors, destructuring, element access, mixed exports,
lexical shadowing, unqualified-name isolation, static-private identity,
merged-namespace visibility, type-only restrictions, constructor prototypes,
cyclic namespace aliases, and a 41-link star-export chain. Neither cycles nor
long chains are omitted when they expose a failure.

Named imports now use known class/value facts before presence-only `any`
fallbacks. Module namespace values contain the complete known runtime export
inventory, including non-class exports and default exports. Bound export queries
separate value availability from type-only bindings and identify namespace alias
owners. Namespace class members do not register bare class names in the importing
scope. Constructor values retain their instance type through `prototype`.

Namespace identities are reserved and completed before publication, preserving
cycles through ordinary object consumption. A cycle exposed a non-terminating
free-type-parameter walk; it now uses a visited worklist with reusable scratch
storage. Export-name enumeration also uses a visited worklist rather than a
fixed depth limit ([`bca0fad95`](https://github.com/home-lang/home/commit/bca0fad95)).
Recursive object completion is separately tested
([`c2331bab6`](https://github.com/home-lang/home/commit/c2331bab6)).

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Imported static-value controls | 84/84 | 84/84 | 52/84 | 84/84 |
| Bound-class export controls | 52/52 | 52/52 | 48/52 | 52/52 |
| Imported nominal-identity controls | 52/52 | 52/52 | 40/52 | 42/52 |
| Existing imported-owner controls | 20/20 | 20/20 | 10/20 | 10/20 |
| Re-export discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global declaration controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Bound-global controls | 56/56 | 56/56 | 44/56 | 44/56 |
| Original imported graph admission | 2/2 | 2/2 | 0/2 | 0/2 |

The nominal audit still fails generic arguments (2 controls) and
private/protected inheritance (8); both positive and negative inheritance
failures are retained. Full workload admission remains **16/18 for Home** and
**18/18 for each baseline**. Both original graph negative controls are still
accepted without diagnostics by Home, so neither graph is eligible for timing.
No new speed or memory claim is made.

This remains a projection of supported source-owned facts, not automatic
cross-file checked-type transfer. Complex members, method/constructor signatures,
generic constraints and heritage still need semantic linkage. Unsupported
exported value types retain their existing limits; a known export inventory is
not proof that every member has a complete checked type. Unavailable namespace
shapes, including JavaScript files outside the bound query's coverage, are kept
unknown and cached as such, not published as incomplete empty objects.

Evidence is retained in `bench/vs_tsgo/results/static-values.csYPot`.
`audit-before-final.log` and `static_values-final.log` use all 84 controls.
Earlier 68/76-case and Debug runs are retained separately; they are not mixed
into the table. The initial cyclic test was stopped after non-termination;
`focused-sample.txt` records its recursive traversal. The passing replacement
is recorded in `checker-focused-v2.log`.

The frozen pre-change binary is `bound-classes.8s4Xq1/home-v1`, SHA-256
`7f71d18f3a1648032b346183267382573f02475b824f5db8c30e0cc463568bd2`.
The final ReleaseFast binary is `static-values.csYPot/home-final`, SHA-256
`9fb67479dbd422678c617facf686d4a09317658e7c4a871084db906bf12572c1`;
its build log is `release.log`. Other final audit logs use `-final.log`.
Audit source SHA-256:
`301fe1b661ab781e6cde0c4ee3eac8074d14d653361d682329c5a7a9239812e5`.

The checker suite passes 4,274/4,274, conformance 1,417/1,417, Program 120/120,
driver 187/187, CLI 69/69, and the benchmark harness 50/50. Fresh callable-identity and callable-union audits
remain 56/56 and 256/256 for all three compilers. Zig formatting checks pass;
targeted Pickier reports no errors and one pre-existing README fragment warning.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_static_values.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_class_bindings.py
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_nominal_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported generic-class baseline and source-owned metadata (untimed)

Tracked in [#524](https://github.com/home-lang/home/issues/524), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416).
Audit commit [`d7f80bd89`](https://github.com/home-lang/home/commit/d7f80bd89)
adds 100 controls: 25 families, each with a positive and appended-only negative
variant in both app root orders. Files, roots and compiler options are identical
across compilers. Positive controls must be silent; negatives must match the
exact diagnostic-code multiset. No timing is collected.

The suite covers named/default/namespace imports, renamed and re-exported
bindings, nested arrays/objects/tuples/unions/functions, method calls, same-owner
and different-owner compatibility, importer-local name isolation, defaults,
dependent defaults and constraints, required/excess argument counts, owner-local
and imported aliases, and recursive aliases. Unsupported cases stay in the audit.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home baseline |
|---|---:|---:|---:|
| Imported generic-class controls | 100/100 | 100/100 | 50/100 |

The frozen Home baseline is `static-values.csYPot/home-final`, SHA-256
`9fb67479dbd422678c617facf686d4a09317658e7c4a871084db906bf12572c1`.
The 300 compiler/case checks produce 50 failures, all Home failures.
Evidence is `bench/vs_tsgo/results/generic-classes.9vD3xi/audit-before.log`;
audit source SHA-256 is
`19a07655d38308109c36714aaa6d9db10638f7758feac67c2ca3404118f8a2e7`.

The metadata foundation
([`af11e4ebf`](https://github.com/home-lang/home/commit/af11e4ebf)) retains parameter identities, defaults, constraints,
variance, nested annotations, declaration origins and recursive references from
the defining source. Imported aliases are resolved in that owner's bound scope;
unsupported forms remain explicit rather than becoming `any` or incomplete
objects. Class-field optional/readonly modifiers are now retained in HIR
([`f0d84813d`](https://github.com/home-lang/home/commit/f0d84813d)), including
comments between a field name, `?` and `:`. This is preparation for the imported
consumer, not a claim that generic instantiation is fixed. The collector is
tested independently and is not yet invoked during production class collection;
unused schemas are not allocated on the compilation path.

The foundation passes 129/129 Program tests (including nine schema controls),
898/898 parser tests, 187/187 driver tests, 69/69 CLI tests and 53/53 benchmark
harness tests. These are targeted foundation checks, not a new full-checker or
conformance checkpoint. Zig formatting passes; targeted Pickier reports no
errors and one pre-existing README link-fragment warning.

An experimental Debug run with schema collection enabled still passes 50/100
generic controls (`audit-foundation-debug.log`); it is not the frozen baseline
or a timing result. The same Debug binary passes all 84 static-value controls
(`static-foundation-debug.log`), as do both pinned baselines. Collection remains disabled in the committed production
path until a checked consumer can use it.

The compiler pins and installed binaries are TS **6.0.3** and native TS **7.0.2**.
The harness rejects `7.0.0-dev.20260707.2` and stable-version suffix mismatches
before collecting results. Native TS 7 and `tsgo` are the same competitor.
The original imported graph admission remains **0/2** for Home; the timing
snapshot above is unchanged and no new performance claim is made.

```sh
HOME_TSC="$PWD/zig-out/bin/home-tsc" python3 bench/vs_tsgo/audit_generic_classes.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Imported generic-class instantiation (untimed)

Tracked in [#524](https://github.com/home-lang/home/issues/524), under
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and
[#416](https://github.com/home-lang/home/issues/416).
The source-owned schema collector is now enabled for generic classes. Imported
type annotations instantiate the defining declaration with the consumer's
actual arguments; defaults, dependent constraints and member expressions resolve
in the declaration's scope. Repeated instances are cached by source declaration
identity and effective arguments. Recursive object aliases with unchanged
arguments retain their object identity, optional members and concrete types.
Non-public members retain declaration origins without synthetic brand fields.
Implementation:
[`0a1e5afe8`](https://github.com/home-lang/home/commit/0a1e5afe8) and
[`33ddbef63`](https://github.com/home-lang/home/commit/33ddbef63).

The audit grew from the historical 100 cases above to **120**: 30 families,
each with a positive and appended-only negative control in both root orders.
The additional families cover growing recursive aliases, unused (phantom) type
parameters, explicit method receivers, resolved `unknown` constraints and weak
optional-object constraints. They were added in
[`96d0da00c`](https://github.com/home-lang/home/commit/96d0da00c),
[`71023f916`](https://github.com/home-lang/home/commit/71023f916),
[`65ea1e895`](https://github.com/home-lang/home/commit/65ea1e895), and
[`bb6f55301`](https://github.com/home-lang/home/commit/bb6f55301).
All compilers receive identical files and options. Positives must be silent;
negatives must match the exact diagnostic-code multiset. No cases are excluded
and no timing is collected.

| Untimed correctness gate | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Imported generic-class controls | 120/120 | 120/120 | 62/120 | 118/120 |
| Imported nominal-identity controls | 52/52 | 52/52 | 42/52 | 44/52 |
| Imported static-value controls | 84/84 | 84/84 | 84/84 | 84/84 |
| Bound-class export controls | 52/52 | 52/52 | 52/52 | 52/52 |
| Original workload admission | 18/18 | 18/18 | 16/18 | 16/18 |
| Imported graph admission (subset above) | 2/2 | 2/2 | 0/2 | 0/2 |

The full 120-case baseline was rerun against the same frozen pre-consumer Home
binary used above; **62/120 is not a reinterpretation of the historical 50/100**.
The new release passes every original 100-case control and 18 of the 20 added
controls. Same-owner phantom parameters remain structurally compatible;
different-owner private members remain incompatible. A detached method with an
explicit `this` requirement is rejected. Resolved `unknown` arguments no longer
bypass constraints. Weak-constraint checking uses apparent object types,
including the declared BigInt wrapper when available; it does not invent
required properties or make primitive `bigint` satisfy the `object` constraint.

Both remaining generic failures are the negative growing-recursion controls:
`Link<X> = { item: X; next?: Link<X[]> }` needs lazy parameterized expansion.
An eager finite graph cannot represent every instantiation. This form remains
unsupported and visible in the audit; there is no fixed-depth truncation or
new `any` substitution to manufacture a passing result. The nominal suite's
eight remaining failures concern private/protected inheritance. Generic
constructors, heritage, generic methods, unsupported annotation forms and full
cross-file checked-type transfer are not established by this checkpoint.
Variance metadata is retained, not a claim of complete variance enforcement.
Issue #524 remains open. Both imported graph timing claims remain ineligible.

Evidence is under `bench/vs_tsgo/results/generic-classes.9vD3xi/`:

- `audit-before-120.log`: 360 compiler/case checks, 58 failures, all Home.
- `audit-final-120.log`: 360 checks, two failures, both Home growing-recursion negatives.
- `nominal_origins-final.log`, `static_values-final.log` and `class_bindings-final.log`: adjacent release audits.
- `admission-final.log`: every original workload checked, including required rejection controls.
- `release-final-v2.log`: successful ReleaseFast build; `home-final`: frozen release binary.

The baseline SHA-256 is
`9fb67479dbd422678c617facf686d4a09317658e7c4a871084db906bf12572c1`.
The new release SHA-256 is
`5a4127f13c8901a1899686b09ca7d62d9bf338f41ff8ea5b43c08d179d35bbb7`.
The 120-case audit source SHA-256 is
`4fa967df7188d6f1b5928e8a8cb1ccfeb5bd25b9b56fed93e0f0f69f10a2a377`.
Version preflight verifies the executable outputs, not just the manifest:
TS **6.0.3** and native TS **7.0.2**. TS 7 and `tsgo` are one competitor;
the old `7.0.0-dev.20260707.2` binary is rejected.

Full verification passes **4,279/4,279 checker**, **1,417/1,417 conformance**,
**130/130 Program**, **187/187 driver**, **69/69 CLI** and **53/53 harness**
tests. Logs are `checker-final.log`, `conformance-final.log`,
`program-final.log`, `driver-final.log`, `cli-final.log` and
`harness-final-120.log`. Fresh release audits also retain callable identity
56/56, callable unions 256/256, graph discovery 28/28 and export origins 32/32
for all three compilers. Home's imported-owner 10/20, global 32/56 and
bound-global 44/56 results remain unchanged; both pinned competitors pass all
of those controls. Logs use the audit's underscore-separated name plus
`-final.log`. Zig formatting checks pass. Targeted Pickier reports zero errors
and one pre-existing README fragment warning (`lint-final.log`).
These are correctness results; the existing timing snapshot is unchanged.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/generic-classes.9vD3xi/home-final" python3 bench/vs_tsgo/audit_generic_classes.py
HOME_TSC="$PWD/bench/vs_tsgo/results/generic-classes.9vD3xi/home-final" python3 bench/vs_tsgo/audit_nominal_origins.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Recursive generic-consumer baseline (untimed)

Follow-up to [#524](https://github.com/home-lang/home/issues/524), with parents
[#521](https://github.com/home-lang/home/issues/521),
[#487](https://github.com/home-lang/home/issues/487), and tracker
[#416](https://github.com/home-lang/home/issues/416).
Audit commits [`6576ff855`](https://github.com/home-lang/home/commit/6576ff855)
and [`42452f823`](https://github.com/home-lang/home/commit/42452f823)
add **216** controls: 16 recursive consumer families and two nonrecursive
calibration families, each tested with a local declaration,
a named import and a namespace import, with paired positive/appended-only
negative uses in both app root orders. All three compilers receive identical
files and options. Positive controls must be silent; negative controls must
produce exactly one TS2322. No cases are excluded and no timing is collected.

| Recursive generic placement | TS 6.0.3 | Native TS 7.0.2 | Home baseline |
|---|---:|---:|---:|
| Local declarations | 72/72 | 72/72 | 16/72 |
| Named imports | 72/72 | 72/72 | 40/72 |
| Namespace imports | 72/72 | 72/72 | 40/72 |
| Total | 216/216 | 216/216 | 96/216 |

The families cover fixed recursion, growing array arguments at depths 1, 4 and
12, growing object arguments, mutually recursive aliases, parameter permutation,
recursive method returns and array members, optional unions, indexed access,
`keyof`, generic inference, destructuring, finite structural targets and
structurally matching distinct recursive origins. Depth variants exercise the
same semantics at different use depths; they do not define an implementation
cutoff. The local controls demonstrate that the remaining problem is not only
cross-file name resolution. The direct-parameter and nonrecursive-member
calibration families pass all 24 controls for all three compilers, distinguishing
the recursive failures from ordinary generic value/member access. All failures
remain visible.

The baseline is the previously verified ReleaseFast binary
`bench/vs_tsgo/results/generic-classes.9vD3xi/home-final`, from implementation
[`33ddbef63`](https://github.com/home-lang/home/commit/33ddbef63), SHA-256
`5a4127f13c8901a1899686b09ca7d62d9bf338f41ff8ea5b43c08d179d35bbb7`.
Evidence: `bench/vs_tsgo/results/recursive-generics.mlQve8/audit-before-216.log`
(648 compiler/case checks, 120 failures, all Home). The initial 192-case run
is separately retained in `audit-before.log` (Home 72/192); the 24 calibration
controls add passes without removing any failures. Final audit source SHA-256:
`65550d718a6369f850474f6699a3d0ec3733da302373fd99ffcb56e31124ff04`.
Executable preflight verifies TS **6.0.3** and native TS **7.0.2**; TS 7 and
`tsgo` remain one competitor.

This **96/216** baseline is not a regression from, or a replacement for, the
distinct **118/120** imported generic-class audit above. Both suites are retained.
Original workload admission remains 16/18, imported graph admission remains
0/2, and the timing snapshot is unchanged. No recursive-generic speed claim is
eligible from this correctness baseline.

The representation foundation
([`c6c6c6652`](https://github.com/home-lang/home/commit/c6c6c6652)) introduces pool-owned generic definitions: a
distinct declaration identity, its declaration-scoped parameter TypeIds, and a
symbolic body. Recursive instantiation references can point back to that
identity without unfolding the body. Construction is two-phase and unpublished
until complete; allocation failure cannot publish a partial parameter list.
Type-pool transfer relocates definitions, parameters, recursive edges and source
provenance together, and rejects incomplete definitions. Separate declarations
remain distinct even when their parameter names or body shapes match.

This is prerequisite representation work. Production lowering still uses the
existing consumer from the preceding checkpoint; shared lazy evaluation and
member/relation/indexed-access consumers have not been connected to the new
definition representation. The audit failures are not claimed fixed, and no
fixed-depth expansion or new permissive fallback is introduced.

Verification passes **4,282/4,282 checker**, **1,417/1,417 conformance**,
**130/130 Program**, **187/187 driver**, **69/69 CLI** and **56/56 harness**
tests. The focused definition tests pass 4/4 and transfer tests 10/10, including
allocation-failure rollback and recursive graph preservation after releasing
the source pool. Evidence is in `recursive-generics.mlQve8/` under
`checker-definitions.log`, `conformance-definitions.log`,
`program-definitions.log`, `driver-definitions.log`, `cli-definitions.log`,
`harness.log`, `definitions-focused.log` and `transfer-focused.log`.
Zig formatting passes; targeted Pickier reports zero errors and the existing
README fragment warning (`lint.log`).

The foundation's ReleaseFast binary is frozen as
`recursive-generics.mlQve8/home-definitions`, SHA-256
`95ababead014327b0e3bc97b7909eae88aeabaf5b2542612ba79fb74ffc6e173`
(`release-definitions.log`). Its fresh 216-case audit retains **96/216** for
Home and **216/216** for both competitors (`audit-definitions-216.log`): all
648 compiler/case outcomes match the pre-foundation baseline. The separate
imported-class suite retains **118/120** for Home and **120/120** for both
competitors (`generic-classes-definitions.log`). Original workload admission
is freshly verified at **16/18** for Home and **18/18** for both competitors
(`admission-definitions.log`); the same two graph rejection gates still fail.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/generic-classes.9vD3xi/home-final" python3 bench/vs_tsgo/audit_recursive_generics.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Lazy source-owned generic consumers

Work for [#524](https://github.com/home-lang/home/issues/524), parents
[#521](https://github.com/home-lang/home/issues/521) and
[#487](https://github.com/home-lang/home/issues/487), tracker
[#416](https://github.com/home-lang/home/issues/416).
[`220a62d57`](https://github.com/home-lang/home/commit/220a62d57) expands the
preceding audit from 216 to **288** controls by adding private-to-module local
declarations. This fourth placement uses the same 18 families, two root orders,
and positive/appended-only-negative pairs. All prior controls remain. Every
compiler receives identical files/options; positive programs must be silent and
negative programs must produce exactly one TS2322. These are correctness
controls, not a recursive-generic throughput benchmark.

The frozen foundation ReleaseFast binary (`c6c6c6652`, SHA-256
`95ababead014327b0e3bc97b7909eae88aeabaf5b2542612ba79fb74ffc6e173`) passes
**112/288**: 16/72 for each local placement and 40/72 for each import placement.
Both TS 6.0.3 and native TS 7.0.2 pass **288/288**. Evidence is
`bench/vs_tsgo/results/lazy-generics.2H3YDX/recursive-before-288.log`.
The added placement exposes 56 additional Home failures; it does not remove or
reclassify any failure from the 216-case baseline. Audit source SHA-256:
`361a6c796efca23e5ef11a76efc119d8d4c7f0b07ecdfbf51acec46d3253ca15`.

Implementation [`3b7f0ea93`](https://github.com/home-lang/home/commit/3b7f0ea93)
builds a declaration-owned symbolic body once, retaining
fresh formal parameter identities. Instantiation substitutes the requested
arguments but leaves nested references symbolic. Member access, indexed access,
expression consumers and structural relations request the same cached expansion;
growing recursion no longer requires eager unfolding. Local generic class
metadata follows the same path without becoming an exported import binding.
Definition identity is based on source owner and declaration position, not a
display name. Transparent aliases preserve the identity of the type they reuse.
No fixed-depth unrolling or new permissive `any` recovery is introduced.

The dedicated growing-recursion test follows 64 requested surfaces and verifies
their concrete arguments, cache reuse and a single generic definition. This test
depth is not an implementation limit. Other focused controls cover owner
separation, dependent defaults, constraints, local export visibility and display
name collisions. Unsupported schema forms remain explicit; this checkpoint does
not establish general imported-function/heritage/mapped-type support or repair
the original graph admission gates by itself.

The final ReleaseFast candidate passes the complete recursive audit:

| Placement or separate audit | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Local exported declarations | 72/72 | 72/72 | 16/72 | 72/72 |
| Local non-exported declarations | 72/72 | 72/72 | 16/72 | 72/72 |
| Named imports | 72/72 | 72/72 | 40/72 | 72/72 |
| Namespace imports | 72/72 | 72/72 | 40/72 | 72/72 |
| Recursive total | 288/288 | 288/288 | 112/288 | 288/288 |
| Imported generic classes (separate suite) | 120/120 | 120/120 | 118/120 | 120/120 |
| Nominal identity (separate suite) | 52/52 | 52/52 | 44/52 | 44/52 |
| Original workload admission | 18/18 | 18/18 | 16/18 | 16/18 |

Evidence is under `bench/vs_tsgo/results/lazy-generics.2H3YDX/`, using the
immutable `release-v5/bin/home-tsc` binary, SHA-256
`267691e33056e2c4a8b23b757bc3eed19c8b3d90fa9407120b8985834a844ccd`.
Logs: `recursive-release-v5.log`, `audit_generic_classes-release-v5.log`,
`audit_nominal_origins-release-v5.log`, and `admission-release-v5.log`.
The 288-case audit makes 864 compiler/case checks with zero failures; the
imported-class audit makes 360 checks with zero failures. Eight Home nominal
inheritance failures and both original graph rejection failures remain visible.

The separate throughput workload
([`de72563b3`](https://github.com/home-lang/home/commit/de72563b3)) consumes 256
distinct payload interfaces through an imported `Box<T>` and four requested
levels of `Link<T[]>`. Every family checks both its complete array container
and its numeric leaf. Before timing, a temporary copy appends nine invalid uses
at the first, middle and last payload: wrong leaf type, wrong nested container,
and missing property. Admission requires exactly six TS2322 and three TS2339
diagnostics; crashes, silent acceptance and incomplete rejection fail the gate.
The original positive corpus is never mutated or replaced for the negative run.

The frozen foundation accepts these invalid uses (`recursive-workload-before.log`)
and is therefore **ineligible** for a before/after timing comparison on this new
workload. All three current compilers pass its positive and negative checks
(`admission-release-v5.log`). The expanded manifest admits 17/19 workloads for
Home and 19/19 for each competitor, while the original 18-workload set remains
16/18 for Home. Adding a passing workload does not repair either failing graph.

Exact committed-source verification passes **4,285/4,285 checker**,
**1,417/1,417 conformance**, **131/131 Program**, **187/187 driver**,
**69/69 CLI**, **9/9 source-owned focus**, and **60/60 benchmark harness** tests.
Logs are `checker-v5.log`, `conformance-v5.log`, `ts_program-v5.log`,
`ts_driver-v5.log`, `ts_cli-v5.log`, `focused-v5.log` and
`harness-recursive-final.log` in the evidence directory above. Earlier
interrupted verification attempts are not counted as passes. Zig formatting
and targeted Pickier checks pass, apart from the pre-existing README fragment
warning (`lint-docs.log`).

Reporting fix [`74d11634e`](https://github.com/home-lang/home/commit/74d11634e)
subsequently raises the harness total to **66/66**
(`harness-report-integrity.log`). Interleaved reports now require the exact
metadata-declared workload/round file set, the rotating compiler order, and one
successful finite positive timing per compiler per round. An unfinished run
cannot print partial averages under a completed-run heading. Missing/extra
rounds, malformed JSON, duplicate compilers and failed samples are rejected,
not filtered. The historical complete report still validates
(`historical-report-check.log`).

Fresh release audits also retain callable identity 56/56, callable unions
256/256, static values 84/84, bound-class exports 52/52, graph discovery 28/28,
and export origins 32/32 for all three compilers. Home's imported-owner 10/20,
global 32/56 and bound-global 44/56 results remain unchanged; each competitor
passes every control in those suites. Logs use `audit_<name>-release-v5.log`.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 bench/vs_tsgo/audit_recursive_generics.py
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload recursive_generics
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Lazy generic checkpoint performance

The full current checkpoint uses compiler `3b7f0ea93` and the frozen release
binary identified above. Raw result directory:
`bench/vs_tsgo/results/20260828T221149Z`; execution log:
`lazy-generics.2H3YDX/timing-release-v5.log`. Apple M3 Pro, arm64, macOS 27.0,
Zig `0.17.0-dev.1441+d5181a9c9`, TS **6.0.3**, native TS **7.0.2**.
TS 7 and tsgo are one competitor. All 17 selected workloads pass current
schema-3 admission before timing. The two failing original graphs are explicitly
excluded, not silently omitted from an all-workload success claim.

Each compiler receives the same generated project, minimal library, strict
checking, `noLib` and `noEmit` options. Three warmups precede 30 fresh-process
timings per compiler/workload, with compiler order rotating in every round.
The complete report validates **510 round files / 1,530 successful samples**.
No measurements are discarded, replaced or trimmed. Means and sample standard
deviations are shown below; ratios compare Home with the faster competitor.

These are **shared-workstation measurements**, not an isolated-host experiment.
This task's builds, tests and audits completed before measurement, but unrelated
CPU and filesystem activity continued. Observed load averages were
13.34 / 37.27 / 42.65 at the start and 9.88 / 21.73 / 34.34 after the run.
Several rows have substantial variance. Interleaving balances order but does
not remove contention or prove statistical significance; the narrow large-case
predicate margin is especially uncertain. Earlier historical timings are retained
elsewhere in this document, not treated as a controlled before/after experiment.

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs faster competitor |
|---|---:|---:|---:|---:|
| Startup | 63.1 ± 1.3 ms | 38.2 ± 1.0 ms | 3.4 ± 0.2 ms | 11.30× faster |
| 256 files | 206.7 ± 2.9 ms | 54.2 ± 2.5 ms | 31.5 ± 0.8 ms | 1.72× faster |
| Deep types | 146.1 ± 58.4 ms | 58.8 ± 19.1 ms | 30.1 ± 11.1 ms | 1.95× faster |
| 128-module import graph | — | — | — | Ineligible: rejection gate fails |
| 64-leaf barrel graph | — | — | — | Ineligible: rejection gate fails |
| TSX components | 161.7 ± 5.2 ms | 47.9 ± 3.1 ms | 23.1 ± 4.7 ms | 2.08× faster |
| Generic calls | 197.7 ± 49.6 ms | 60.7 ± 18.9 ms | 25.6 ± 8.7 ms | 2.37× faster |
| Control flow | 219.0 ± 78.6 ms | 67.6 ± 18.4 ms | 39.9 ± 18.3 ms | 1.69× faster |
| Type predicates | 322.9 ± 151.3 ms | 88.1 ± 33.6 ms | 53.5 ± 16.9 ms | 1.65× faster |
| Large type predicates | 1120.0 ± 211.7 ms | 393.6 ± 94.1 ms | 377.0 ± 100.9 ms | 1.04× lower mean; noisy |
| Null-safe access | 223.1 ± 75.3 ms | 69.7 ± 26.0 ms | 52.0 ± 25.9 ms | 1.34× faster |
| Destructuring | 156.0 ± 18.2 ms | 50.7 ± 4.0 ms | 37.7 ± 7.1 ms | 1.34× faster |
| Overload resolution | 224.9 ± 27.2 ms | 70.2 ± 6.5 ms | 33.6 ± 9.5 ms | 2.09× faster |
| Class hierarchy | 335.8 ± 90.2 ms | 76.8 ± 17.7 ms | 45.3 ± 14.8 ms | 1.69× faster |
| Structural objects | 229.8 ± 28.9 ms | 71.1 ± 12.3 ms | 35.5 ± 4.9 ms | 2.01× faster |
| Interface composition | 241.4 ± 39.7 ms | 73.6 ± 13.5 ms | 52.5 ± 10.3 ms | 1.40× faster |
| Variadic tuples | 275.0 ± 12.9 ms | 84.3 ± 5.7 ms | 48.0 ± 7.9 ms | 1.76× faster |
| Checked JavaScript/JSDoc | 210.3 ± 9.9 ms | 56.4 ± 7.2 ms | 39.8 ± 6.4 ms | 1.42× faster |
| Recursive generic payloads | 151.7 ± 2.2 ms | 71.8 ± 1.1 ms | 29.7 ± 0.2 ms | 2.42× faster |

Home has lower means on **17/17 timed workloads**, while expanded admission
remains **17/19**. In paired rounds Home beats native TS 7 in 30/30 recursive
rounds and 24/30 large-predicate rounds. These observations are not proof of
universal, real-project or cross-platform leadership. This correctness
implementation is not claimed to accelerate the old compiler: its predecessor
fails the new recursive workload's rejection controls, so that speed comparison
would not represent equivalent semantic work.

```sh
# Run all currently eligible workloads; failing graph gates stay explicitly excluded.
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 -c 'import sys; sys.path.insert(0,"bench/vs_tsgo"); import run; run.cmd_cold(30, 3, [w for w in run.manifest()["workloads"] if w not in ("import_graph", "reexport_graph")])'
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T221149Z
```

After the full run, an independent 30-round confirmation was declared for the
new recursive workload and the narrowest mean margin, large predicates. It uses
the same frozen binary, three warmups, pinned competitors and admission gates.
Results are retained separately in `20260828T221611Z`
(`lazy-generics.2H3YDX/timing-confirmation-v5.log`):

| Confirmation workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs faster competitor |
|---|---:|---:|---:|---:|
| Large type predicates | 1151.5 ± 272.4 ms | 392.7 ± 83.0 ms | 349.9 ± 17.0 ms | 1.12× faster |
| Recursive generic payloads | 156.6 ± 14.2 ms | 73.1 ± 3.9 ms | 29.6 ± 0.7 ms | 2.47× faster |

All **60 round files / 180 samples** validate. Home beats native TS 7 in
28/30 paired large-predicate rounds and 30/30 recursive rounds. These numbers
do not replace, get averaged into, or erase the first run's noisy 1.04× margin.
The shared-host and incomplete-coverage qualifications still apply.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/lazy-generics.2H3YDX/release-v5/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload type_predicates_large --workload recursive_generics
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T221611Z
```

### Source-owned exported factory contracts (untimed)

Commit `de8fe28f1`, issue [#534](https://github.com/home-lang/home/issues/534), under
[#487](https://github.com/home-lang/home/issues/487) and
[#416](https://github.com/home-lang/home/issues/416), extends the source-owned
graph to exported interfaces, type aliases, annotated variables and functions.
The old exported-value collector scanned declaration-file lines and discarded
generic signatures. The replacement resolves bound export identities, including
aliases and export-star paths, and shares one annotation graph before checking
consumers. Function signatures retain formal parameter identities, constraints,
ordered defaults, required/rest parameters, receiver types and parameterized
returns. It does not infer missing owner annotations or publish a partial
overload/merged-interface graph as a complete type.

`audit_graph_types.py` retains **240** controls: twelve semantic families across
local, named-import, namespace-import and two two-hop barrel placements, both
root orders, each with a positive and appended-only negative program. Both
compilers receive the same files and strict project configuration. Controls
exercise explicitly annotated interfaces, inferred factory results, wrong
property types, missing/readonly members, explicit type arguments, constraints,
required arity, ordinary/rest arguments, dependent defaults, captured factories
and consumer-local name collisions. A clean positive alone is not a pass:
the negative must emit exactly its expected diagnostic code.

| Untimed control | TS 6.0.3 | Native TS 7.0.2 | Home baseline `3b7f0ea93` | Home `de8fe28f1` Release |
|---|---:|---:|---:|---:|
| Factory contracts | 240/240 | 240/240 | 130/240 | 240/240 |
| Original graph admission | 2/2 | 2/2 | 0/2 | 2/2 |
| Static-value controls | 84/84 | 84/84 | 84/84 | 84/84 |
| Nominal-origin controls | 52/52 | 52/52 | 44/52 | 44/52 |
| Imported-owner controls | 20/20 | 20/20 | 10/20 | 12/20 |
| Recursive generic controls | 288/288 | 288/288 | 288/288 | 288/288 |
| Generic-class controls | 120/120 | 120/120 | 120/120 | 120/120 |
| Bound-class controls | 52/52 | 52/52 | 52/52 | 52/52 |
| Callable identity controls | 56/56 | 56/56 | 56/56 | 56/56 |
| Callable union controls | 256/256 | 256/256 | 256/256 | 256/256 |
| Graph discovery controls | 28/28 | 28/28 | 28/28 | 28/28 |
| Export-origin controls | 32/32 | 32/32 | 32/32 | 32/32 |
| Global controls | 56/56 | 56/56 | 32/56 | 32/56 |
| Bound-global controls | 56/56 | 56/56 | 44/56 | 44/56 |

Evidence is retained in `bench/vs_tsgo/results/graph-types.4EsbvV/`:
`audit-before.log`, `audit-v2.log`, `audit-v3.log`, `graphs-v2.log`,
`static_values-v2.log`, and `nominal_origins-v2.log`. The intermediate candidate
passed 220/240 factory controls; its twenty dependent-default failures remain
recorded. Applying defaults using owner-resolved type parameter payloads, in
declaration order, removes those failures without changing the controls.
Release repeats are in the corresponding `*-release-v3.log` files. The eight
inherited private/protected nominal-origin failures remain open, as do eight
imported-owner predicate/rest controls and the existing global-control failures.

All **19/19 workloads pass Release admission**, including the unchanged original
graph, tuple, destructuring, predicate and recursive-generic rejection controls
(`admission-release-v3.log`). Full relevant suites pass: **4,286/4,286 checker**,
**1,417/1,417 conformance**, **133/133 Program**, **187/187 driver**, **69/69 CLI**,
**10/10 source-owned focus**, and **69/69 benchmark-harness** tests. These are the
named repository suites, not a claim of complete upstream TypeScript parity.

The frozen binary is `graph-types.4EsbvV/release-v3/bin/home-tsc`, SHA-256
`9f5e333beaf9828a9720ce260ae05a872ebcea3bb51bf5785ffa3ccd7b72f1bc`.
These correctness results are **not timing claims**. The earlier measured
snapshot above still refers to its original frozen binary. A profile also
identified redundant source compilation in CommonJS export queries; follow-up
[#536](https://github.com/home-lang/home/issues/536) will use this corrected
version as its comparison baseline, never the previously ineligible graph run.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/graph-types.4EsbvV/release-v3/bin/home-tsc" python3 bench/vs_tsgo/audit_graph_types.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

### Exported-factory checkpoint performance

The complete run `20260828T224220Z` measures the frozen `de8fe28f1` ReleaseFast
binary above against **TS 6.0.3** and **native TS 7.0.2**. All **19/19 workloads**
pass admission before measurement, including the unchanged original graph
rejection controls. All **570 round files / 1,710 successful samples** pass the
reporter's coverage, rotating-order, exit-status and finite-duration checks.
Fresh generation independently matches all **513 measured corpus files** byte
for byte (`graph-types.4EsbvV/corpus-verified-v3.log`). No samples are discarded.

Environment: Apple M3 Pro, arm64, macOS 27.0, shared workstation; 30 interleaved
fresh-process measurements per compiler/workload after three warmups. This
task's builds, tests and audits finished before timing. Unrelated CPU and
filesystem activity continued, including another Zig compilation. Load averages
were 6.17 / 8.23 / 12.63 before the run and 6.79 / 7.03 / 10.92 afterward.
Interleaving balances order, not all contention. Means and sample standard
deviations below are observations, not statistical proof of universal leadership.

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs faster competitor |
|---|---:|---:|---:|---:|
| Startup | 68.9 ± 6.2 ms | 40.9 ± 0.9 ms | 3.6 ± 0.1 ms | 11.45× faster |
| 256 files | 220.8 ± 9.7 ms | 57.0 ± 5.4 ms | 34.8 ± 1.5 ms | 1.64× faster |
| Deep types | 131.5 ± 5.3 ms | 52.8 ± 1.7 ms | 26.5 ± 0.5 ms | 2.00× faster |
| 128-module import graph | 145.5 ± 35.6 ms | 50.8 ± 9.9 ms | 33.7 ± 7.4 ms | 1.51× faster |
| 64-leaf barrel graph | 97.2 ± 11.8 ms | 41.1 ± 1.1 ms | 25.1 ± 3.2 ms | 1.63× faster |
| TSX components | 160.4 ± 1.9 ms | 47.0 ± 1.0 ms | 26.3 ± 0.4 ms | 1.79× faster |
| Generic calls | 190.1 ± 21.9 ms | 56.5 ± 4.5 ms | 24.2 ± 1.2 ms | 2.34× faster |
| Control flow | 210.1 ± 37.7 ms | 63.2 ± 5.0 ms | 44.9 ± 7.0 ms | 1.41× faster |
| Type predicates | 259.9 ± 32.0 ms | 80.5 ± 16.2 ms | 50.5 ± 8.9 ms | 1.59× faster |
| Large type predicates | 1071.8 ± 87.3 ms | 380.6 ± 44.8 ms | 541.3 ± 50.7 ms | **1.42× slower** |
| Null-safe access | 198.3 ± 15.7 ms | 58.8 ± 3.1 ms | 41.9 ± 1.8 ms | 1.40× faster |
| Destructuring | 143.6 ± 4.6 ms | 49.8 ± 2.2 ms | 38.6 ± 4.5 ms | 1.29× faster |
| Overload resolution | 204.7 ± 11.0 ms | 66.7 ± 5.2 ms | 30.5 ± 1.4 ms | 2.19× faster |
| Class hierarchy | 193.5 ± 18.1 ms | 55.7 ± 4.2 ms | 29.9 ± 1.3 ms | 1.86× faster |
| Structural objects | 207.2 ± 19.7 ms | 63.9 ± 4.7 ms | 32.4 ± 1.8 ms | 1.97× faster |
| Interface composition | 214.1 ± 14.0 ms | 68.5 ± 6.1 ms | 47.8 ± 4.6 ms | 1.43× faster |
| Variadic tuples | 280.3 ± 21.4 ms | 85.8 ± 5.3 ms | 49.4 ± 4.0 ms | 1.74× faster |
| Checked JavaScript/JSDoc | 233.9 ± 21.7 ms | 60.0 ± 4.2 ms | 39.4 ± 0.8 ms | 1.52× faster |
| Recursive generic payloads | 166.8 ± 12.2 ms | 77.0 ± 7.5 ms | 30.9 ± 1.3 ms | 2.49× faster |

Home has lower means on **18/19**, not all workloads. It beats native TS 7 in
29/30 import-graph and 30/30 re-export-graph paired rounds, but **0/30 large
predicate rounds**. The losing row is retained and tracked by
[#537](https://github.com/home-lang/home/issues/537). Historical results suggest
a scaling regression worth investigating; they are not a controlled before/after
comparison. The cause must be established against a same-correctness baseline.
Broader rejection coverage, real-project and cross-platform measurements, and
the remaining correctness failures above still prevent an overall completion claim.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/graph-types.4EsbvV/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T224220Z
```

The full console record and rendered report are retained as
`graph-types.4EsbvV/timing-release-v3.log` and `report-release-v3.md`.

A separate same-host before/after diagnostic confirms the large-predicate
regression: frozen `3b7f0ea93` takes **351.0 ± 16.9 ms**, versus `de8fe28f1`
**533.8 ± 14.9 ms**, a **1.52× slowdown**. Both binaries first pass this same
workload's positive and unchanged predicate rejection controls. Three warmups
per binary precede thirty two-process rounds, alternating before/after order;
all **30 rounds / 60 successful samples** are retained in
`graph-types.4EsbvV/predicate-ab-v3/` with binary paths, versions and hashes.
The newer binary loses all thirty paired rounds. This diagnostic is not averaged
into the three-compiler table and says nothing about the old binary's eligibility
for the graph workloads. Source inspection identifies repeated whole-block
export-name scans as a candidate cost to investigate under #537. The subsequent
indexed-export checkpoint below implements and verifies that optimization.

### Indexed export queries and variable-list ownership

Commit `b7b9dd9ee`, follow-up [#537](https://github.com/home-lang/home/issues/537), replaces repeated
whole-source export/import scans with an index of each prepared owner's bound
declarations and unresolved alias/star edges. The index is built once per owner;
queries still traverse relevant edges with their own visibility and cycle state.
It does not cache a permissive answer or skip type checking. Lexical edge order,
explicit-export precedence, default exports, type-only restrictions, merged
symbols and declaration provenance are preserved.

An operation-count regression proves the repeated work independently of timing:
resolving 128 exports from a 256-statement source previously visited **65,536**
root statements; the indexed query visits **256**, including subsequent missing
and hidden-name queries. Test-only accounting is absent from production builds.
The original failing test output is retained as
`export-index.NVcIdu/program-before.log`; the indexed/ownership Program suite
passes **137/137**, including ambiguity, cycles, destructured declarations,
provenance and allocation-failure cleanup.

Those tests also exposed an existing parser bug: trailing declarators in
`export const first = 1, second = 2` were emitted as unexported siblings.
Commit `d6878e880` ([#538](https://github.com/home-lang/home/issues/538)) preserves export ownership
for every declarator, without inferring it from source text in the index.
The parser suite passes **891/891** tests.

The new `audit_export_lists.py` has 96 untimed cases across const/let/var/declare-var,
named/namespace/two-hop barrel imports, both root orders, and identical positives
with appended wrong-type or hidden-binding negatives. Both pinned TypeScript
compilers pass all cases. Frozen Home `de8fe28f1` fails all 96; the new candidate
passes **80/96**, with the expected diagnostic codes unchanged:

| Export-list control | TS 6.0.3 | Native TS 7.0.2 | Home before | Home after |
|---|---:|---:|---:|---:|
| Valid trailing-member consumption | 32/32 | 32/32 | 0/32 | 32/32 |
| Wrong trailing-member type | 32/32 | 32/32 | 0/32 | 32/32 |
| Hidden name through a barrel | 16/16 | 16/16 | 0/16 | 16/16 |
| Hidden name imported directly | 16/16 | 16/16 | 0/16 | 0/16 |

The remaining direct hidden imports are rejected, but with TS2305 instead of
TS2459. They remain failures, tracked by
[#540](https://github.com/home-lang/home/issues/540); currently the more precise
local-declaration diagnostic is available for virtual same-HIR modules but not
real external owners. Evidence: `export-index.NVcIdu/export-lists-before.log`
and `export_lists-v3.log`.

All **19/19 workloads pass admission**. Existing release audits retain their
previous scores: factory 240/240, recursive 288/288, generic classes 120/120,
static 84/84, bound classes 52/52, callable identity 56/56, callable unions 256/256,
graph discovery 28/28, export origins 32/32, owners 12/20, nominal origins 44/52,
globals 32/56 and bound globals 44/56. No pre-existing failure is removed.
Relevant suites pass: checker **4,286/4,286**, conformance **1,417/1,417**,
Program **137/137**, parser **891/891**, driver **187/187**, CLI **69/69**,
emitter **499/499**, and benchmark harness **72/72**. Disk-space-failed build logs
are retained; successful retries are separately named `*-v3-retry.log`.

The frozen ReleaseFast binary is
`export-index.NVcIdu/release-v3/bin/home-tsc`, SHA-256
`615e9fa1f78c2cad17a0b8911b897ede73c00422138d6ecbb2b74801d4564f14`.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/audit_export_lists.py
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
```

The controlled large-predicate before/after run uses frozen `de8fe28f1` and
`b7b9dd9ee`, both of which first pass this workload and its unchanged predicate
rejection controls. After three warmups per binary, thirty rounds alternate the
before/after process order. All **30 round files / 60 successful finite samples**
are retained in `export-index.NVcIdu/predicate-ab-v3/`, with paths, versions and
SHA-256 hashes; console summary: `predicate-ab-v3.log`.

The previous build averages **525.6 ± 12.4 ms** and the indexed build
**353.5 ± 10.5 ms**: **32.7% less time**, with the new build faster in **30/30**
paired rounds. This comparison is restricted to an input on which both builds
pass the same semantic controls. It is separate from the earlier regression
measurement and from the full three-compiler run; results are not averaged
together. The operation-count test and same-correctness measurement support
removing the repeated export-query scans, not skipping semantic work.

### Indexed-export checkpoint performance

The complete `b7b9dd9ee` checkpoint, `20260828T231439Z`, uses the frozen binary
above on an Apple M3 Pro, arm64, macOS 27.0 shared workstation. The harness
verifies **TS 6.0.3 and native TS 7.0.2** before admission; TS 7 and `tsgo` are
one competitor. All 19 positive workloads and their unchanged rejection gates
pass on all three compilers before measurement. After three warmups, 30 rounds
rotate compiler order for every workload. Integrity validation accepts all
**570 round files / 1,710 successful finite samples**. Fresh generation after
timing matches all **513 measured corpus files byte-for-byte**.

Own builds, tests and audits had finished before timing, but unrelated shared-host
activity remained. Load averages before/after were 5.51 / 15.13 / 14.10 and
4.72 / 10.21 / 12.23. No rounds or outliers were discarded. Times below are
mean ± sample standard deviation; ratios use unrounded means and the faster
competitor (native TS 7 for every row).

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 65.3 ± 3.2 ms | 39.5 ± 2.9 ms | 3.3 ± 0.2 ms | 11.82× faster |
| `many_files` | 216.5 ± 18.0 ms | 57.0 ± 4.9 ms | 38.1 ± 12.4 ms | 1.50× faster |
| `deep_types` | 137.5 ± 12.3 ms | 55.2 ± 4.3 ms | 28.2 ± 2.6 ms | 1.96× faster |
| `import_graph` | 140.7 ± 14.4 ms | 49.2 ± 5.8 ms | 33.3 ± 4.4 ms | 1.48× faster |
| `reexport_graph` | 99.1 ± 4.3 ms | 44.1 ± 8.9 ms | 25.6 ± 3.1 ms | 1.72× faster |
| `tsx_components` | 162.8 ± 6.6 ms | 47.5 ± 1.3 ms | 23.8 ± 3.3 ms | 1.99× faster |
| `generic_calls` | 181.4 ± 13.4 ms | 56.1 ± 4.2 ms | 23.0 ± 0.8 ms | 2.44× faster |
| `control_flow` | 194.3 ± 10.4 ms | 61.3 ± 7.7 ms | 36.5 ± 1.9 ms | 1.68× faster |
| `type_predicates` | 248.1 ± 8.2 ms | 74.0 ± 1.8 ms | 45.4 ± 1.2 ms | 1.63× faster |
| `type_predicates_large` | 1053.4 ± 204.0 ms | 377.7 ± 66.4 ms | 371.6 ± 125.5 ms | 1.02× lower mean; noisy |
| `null_safe_access` | 189.6 ± 8.8 ms | 61.1 ± 23.1 ms | 39.7 ± 1.0 ms | 1.54× faster |
| `destructuring` | 145.0 ± 20.3 ms | 49.5 ± 9.2 ms | 36.6 ± 6.8 ms | 1.35× faster |
| `overload_resolution` | 194.1 ± 4.0 ms | 62.5 ± 1.5 ms | 29.1 ± 0.8 ms | 2.15× faster |
| `class_hierarchy` | 178.9 ± 19.5 ms | 50.6 ± 1.9 ms | 28.2 ± 3.0 ms | 1.79× faster |
| `structural_objects` | 180.0 ± 14.9 ms | 56.2 ± 1.2 ms | 29.2 ± 0.9 ms | 1.92× faster |
| `interface_composition` | 191.7 ± 1.7 ms | 60.4 ± 1.1 ms | 42.9 ± 0.4 ms | 1.41× faster |
| `variadic_tuples` | 242.4 ± 6.7 ms | 76.1 ± 2.7 ms | 42.9 ± 1.3 ms | 1.77× faster |
| `checkjs_jsdoc` | 204.9 ± 6.4 ms | 54.7 ± 2.4 ms | 38.0 ± 1.5 ms | 1.44× faster |
| `recursive_generics` | 157.2 ± 10.9 ms | 73.9 ± 3.5 ms | 30.2 ± 1.7 ms | 2.45× faster |

Home has lower means on **19/19**, but this is not universal or statistically
established benchmark leadership. Large predicates lead by only 1.02× with
substantial variance and **25/30 paired wins** over TS 7. Import graph, re-export
graph and many-files paired wins are 29/30, 30/30 and 29/30 respectively.
Real projects, additional platforms and the outstanding correctness gaps above
remain unvalidated. The earlier losing checkpoint stays documented separately.

An independent large-predicate confirmation, `20260828T231856Z`, uses the same
binary, unchanged controls, three warmups and 30 rotating-order rounds. All
**30 round files / 90 successful samples** validate. Home has the lower time
in **29/30 paired rounds**; the margin remains narrow. This targeted run is
reported separately, not substituted for the full-run row or pooled with it:

| Confirmation workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `type_predicates_large` | 950.2 ± 6.6 ms | 331.4 ± 4.6 ms | 320.4 ± 2.8 ms | 1.03× faster |

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T231439Z
HOME_TSC="$PWD/bench/vs_tsgo/results/export-index.NVcIdu/release-v3/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload type_predicates_large
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T231856Z
```

Full-run, confirmation and input-integrity logs are retained locally as
`export-index.NVcIdu/timing-v3.log`, `confirmation-v3.log` and
`corpus-verified-v3.log`. Raw round files and metadata remain in their named
result directories under `bench/vs_tsgo/results/`; they are not combined with
any earlier checkpoint.

### Prepared CommonJS export queries

Commit `1cfc33c1a`, follow-up [#536](https://github.com/home-lang/home/issues/536), removes a repeated
compilation in the empty-name export query. The CLI previously read the file
and ran a complete parse/bind/check to find a CommonJS constructor name before
obtaining its already cached bound module. The query now borrows that prepared
owner's HIR and bindings directly; the conformance adapter retains prepared
owners for both shape and export-table queries as well. The source-only API
prepares bindings but no longer checks merely to answer this shape question.

Raw `module.exports` substring recovery is removed. Display names come from
bound class constructors and const aliases, not comments, strings, unbound
names or unrelated function constructors. Local `module` bindings are
distinguished from the CommonJS wrapper binding. Multiple export assignments
do not get flattened into the first class's name: this single-class display
fact is absent when the actual union type is needed. This metadata query does
not replace semantic type checking or supply an `any` type.

The new audit in commit `d95dfaac1` also exposes a separate cross-file typing
gap, tracked by [#541](https://github.com/home-lang/home/issues/541). It includes
11 source forms, both root orders, valid consumption, and the identical program
with an appended wrong-type or missing-member use. Every configuration
explicitly lists the JavaScript files and enables strict `allowJs`/`checkJs`.
Both pinned compilers pass **66/66**; frozen Home `b7b9dd9ee` passes **22/66**:

| Untimed CommonJS control | TS 6.0.3 | Native TS 7.0.2 | Home baseline |
|---|---:|---:|---:|
| Valid instance consumption | 22/22 | 22/22 | 22/22 |
| Wrong consumed member type (TS2322) | 22/22 | 22/22 | 0/22 |
| Missing member (TS2339) | 22/22 | 22/22 | 0/22 |

The missing 44 diagnostics are retained, not waived. CommonJS instance
consumption is **not a timed workload**. Reassignment can produce union types;
TS 6 and TS 7 differ in union ordering/display for some probes, so the shared
audit compares exact diagnostic-code multisets, not an invented common wording.

```sh
python3 bench/vs_tsgo/audit_commonjs.py
python3 -m unittest discover -s bench/vs_tsgo -p 'test_*.py'
```

Evidence is retained locally in `bench/vs_tsgo/results/commonjs-query.hyU20d/`:
`audit-before.log` records the 198 checks. `probe-roots-before.log` includes
diagnostic wording. The initial `probe-before.log` accidentally excluded JS
via a TS-only include and is **not valid admission evidence**; the replacement
uses explicit JS roots, and harness tests now enforce those roots and flags.

The ReleaseFast candidate is `commonjs-query.hyU20d/release-v1/bin/home-tsc`,
SHA-256 `573257a819a178c9387f6d02a7992c08f995185f5dbc94034eb5eadc0ae956c0`.
All **19/19** existing workload admission gates pass before timing. The complete
15-audit comparison checks case identities as well as totals: **every previously
passing case still passes**. Home's CommonJS result remains 22/66 and all other
audit scores remain unchanged, including exported factories 240/240, recursive
generics 288/288, exported variable lists 80/96, nominal origins 44/52, owners
12/20, globals 32/56 and bound globals 44/56. Both competitors pass every case.

Program **140/140**, conformance **1,418/1,418**, CLI **69/69** and harness
**75/75** tests pass; unchanged checker and driver targets verify from cache.
Program tests cover bound aliases,
shadowing, comments/strings, multiple assignments, and 128 repeated queries with
an unchanged HIR/type pool and no checked-owner state. Conformance adds cache
identity checks in both JavaScript modes. Three disk-interrupted audit logs are
retained alongside complete `*-v1-retry.log` replacements; the final per-case
verification is `verification-final.log`. No incomplete audit was counted as
passing, and no source, frozen compiler or benchmark evidence was deleted.
The first conformance command returned success but lost its console output
during disk exhaustion; the complete successful retry is retained as
`conformance-v1-retry.log`.

### Static CommonJS dependency discovery (untimed)

Commits `0ebdba7ef` and `eaf86ee56`, tracked by
[#545](https://github.com/home-lang/home/issues/545), add an untimed graph audit
and make Program closure discovery follow static JavaScript `require` calls.
The implementation traverses parsed HIR, accepts exactly one string-literal-like
argument (including a no-substitution template), and preserves lexical edge
order. It does not scan source text. Comments, strings, computed specifiers,
property calls, interpolated templates and multiple-argument calls remain
excluded. Cycles and diamonds retain unique current edges after recompilation.

The audit contains 44 projects and runs each through all three compilers, for
132 exact diagnostic-code checks. Six followed families cover binding, nested,
template, transitive, cyclic and diamond graphs. Five decoy families cover
comments, strings, dynamic specifiers, property calls and multiple arguments.
Every family has entry-only and all-file roots, plus a positive project and an
otherwise identical negative that only appends TS2322 to the leaf. This makes
dependency inclusion observable without treating an absent error as success.

| Untimed static-`require` controls | TS 6.0.3 | Native TS 7.0.2 | Frozen Home before | Home after |
|---|---:|---:|---:|---:|
| Followed graph shapes | 24/24 | 24/24 | 18/24 | 24/24 |
| Ignored lookalikes | 20/20 | 20/20 | 20/20 | 20/20 |
| **Total** | **44/44** | **44/44** | **38/44** | **44/44** |

The frozen before binary is the `1cfc33c1a` release used by the prepared-query
checkpoint. The immutable after binary is
`commonjs-discovery.JMl1yj/release-v1/bin/home-tsc`, SHA-256
`31679b8aeb0a6279880dbdd140e25fd891a07e7967a36e92324f82b3776df5e7`.
Program **143/143**, the 78-test Python harness, checker, driver, CLI and the
conformance target pass. The conformance target reports smoke **16/16**, named
categories **86/86** and baseline-aware categories **586/586**. Raw before,
after, conformance and unchanged-gap logs are retained locally in
`bench/vs_tsgo/results/commonjs-discovery.JMl1yj/`.

This is a correctness result, not a timed workload or a performance claim. At
this checkpoint the separate CommonJS instance audit remained TS 6 **66/66**,
native TS 7 **66/66**, Home **22/66**. Static graph discovery was the
prerequisite for the checked-owner transfer documented in the next section; it
was not itself a substitute for that transfer.

### Checked CommonJS export type transfer (untimed)

Follow-up [#541](https://github.com/home-lang/home/issues/541) transfers the
checked declaration owner's actual `module.exports` types into each requiring
consumer. The projection starts from the owner's checked type IDs, preserving
inferred fields, literal widening, reassignment unions, functions, tuples,
arrays, plain objects and class declaration identity. Unsupported shapes remain
explicitly unsupported; the implementation does not infer types from source
spelling or add diagnostic-only recovery.

Program resolves the bound dependency graph before checking and checks owners
before consumers. Serial and streaming execution use the same dependency order.
Parallel execution retains the ordinary parallel path for programs that do not
need whole CommonJS export transfer and uses dependency order when those checked
owner schemas are required. Tests cover all three execution modes and both
owner/app insertion orders.

The unchanged 66-case audit verifies exact diagnostic-code multisets with
version-checked TS **6.0.3** and native TS **7.0.2**. Eleven source families each
run in both root orders with a valid consumer, an otherwise identical TS2322
control, and an otherwise identical TS2339 control:

| Untimed CommonJS control | TS 6.0.3 | Native TS 7.0.2 | Frozen Home before | Home after |
|---|---:|---:|---:|---:|
| Valid instance consumption | 22/22 | 22/22 | 22/22 | 22/22 |
| Wrong consumed member type (TS2322) | 22/22 | 22/22 | 0/22 | 22/22 |
| Missing member (TS2339) | 22/22 | 22/22 | 0/22 | 22/22 |
| **Total** | **66/66** | **66/66** | **22/66** | **66/66** |

The audit performs **198/198** compiler/case checks with zero failures. The
static-`require` discovery audit also remains **132/132** checks with zero
failures. The final immutable ReleaseFast candidate is
`commonjs-linkage.gyKMKg/release-v6/bin/home-tsc`, SHA-256
`3820830f2cd4c4f680164dc7cd1c87ac3294ef803c37e9c44cab7a76559c2c14`.
Raw audit and harness logs are retained locally under
`bench/vs_tsgo/results/commonjs-linkage.gyKMKg/`.

Program **145/145**, the 82-test Python harness, checker, driver and CLI suites
pass. The conformance target reports smoke **16/16**, named categories
**86/86**, and baseline-aware categories **586/586**. This is a correctness
benchmark only; no CommonJS timing is admitted by this result.

### Checked CommonJS graph performance

Issue [#546](https://github.com/home-lang/home/issues/546) adds the first timed
CommonJS graph only after the checked-owner transfer above reached full audit
parity. The deterministic project has 128 checked-JavaScript owners and one
consumer. Each owner exports an inferred service object, then reassigns
`module.exports` to an alternate shape so the consumer must use the real
cross-file union. The admission copy injects wrong-label and missing-member
uses into the first, middle, and last owner. TS 6.0.3, native TS 7.0.2, and Home
must each emit exactly three `TS2322` and three `TS2339` diagnostics before any
timing directory can be created.

The first admitted result, `20260829T010034Z`, retained the loss: Home took
62.8 ± 1.2 ms versus native TS 7 at 51.1 ± 2.1 ms, or 1.23× longer. The
general fixes resolve dependency edges once, schedule dependency-ready files in
parallel batches, avoid redundant graph resolution and irrelevant schema scans,
index actual HIR `var` declarations instead of repeatedly scanning source text,
and cache the immutable Node reference-directive fact. These changes preserve
the checked schema and do not add recovery, source-spelling inference, or a
benchmark-specific fast path.

The exact same-correctness Home A/B compares the original correct release-v2
binary with release-v6. It uses three warmups and 30 alternating-order rounds;
all 30 round files and 60 finite samples are retained, with none removed:

| `commonjs_graph` Home A/B | Correct release-v2 | Optimized release-v6 | After / before | Lower after time |
|---|---:|---:|---:|---:|
| 128 owners + consumer | 62.33 ± 1.49 ms | **42.96 ± 0.92 ms** | **0.689 (31.1% less time)** | **30/30 rounds** |

The complete admitted result is **`20260829T013535Z`**. It uses the same Apple
M3 Pro arm64/macOS 27.0 host, three warmups, 30 rotating-order rounds, and the
exact pins TS **6.0.3** and native TS **7.0.2**. TS 7 and `tsgo` are one
competitor. The full 20-row table is the [current snapshot](#current-snapshot).
Home records the lower mean on **20/20** rows. On `commonjs_graph`, TS 6 takes
148.9 ± 2.5 ms, native TS 7 takes 48.3 ± 1.4 ms, and Home takes
**42.1 ± 0.7 ms**, a **1.15×** lead with 30/30 paired wins. Integrity
validation retains **600 round files / 1,800 successful finite samples** with
no omitted row or discarded sample.

The 1.01× `type_predicates_large` mean margin has only 24/30 paired wins and
must be treated as narrow. `generic_calls` and `overload_resolution` each have
29/30 paired wins and visible variance. The other 17 rows have 30/30 paired
wins. This checkpoint establishes the local admitted synthetic result, not
universal leadership; real-project, cross-platform, and broader semantic
coverage remain open.

The final candidate is
`bench/vs_tsgo/results/commonjs-linkage.gyKMKg/release-v6/bin/home-tsc`, SHA-256
`3820830f2cd4c4f680164dc7cd1c87ac3294ef803c37e9c44cab7a76559c2c14`.
Evidence is retained in `bench/vs_tsgo/results/commonjs-linkage.gyKMKg/` and
`bench/vs_tsgo/results/20260829T013535Z/`, including the release-v2/release-v6
A/B, the initial loss, complete report, commands, audits, and harness logs.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/commonjs-linkage.gyKMKg/release-v6/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260829T013535Z
```

Verification for the final source and candidate: CommonJS transfer **198/198**
checks, static CommonJS discovery **132/132** checks, Python harness **82/82**,
Program **145/145**, checker, driver, and CLI suites green; conformance smoke
**16/16**, named categories **86/86**, and baseline-aware categories **586/586**.

### Prepared-query checkpoint performance

The same-correctness before/after diagnostic compares frozen `b7b9dd9ee` with
`1cfc33c1a`. Both first pass the original import and re-export graph positives
and their unchanged negative controls. Each workload has three warmups per
binary followed by 30 rounds alternating process order. All **60 round files /
120 successful finite samples** are retained in
`commonjs-query.hyU20d/graph-ab-v1/`, including commands, versions and hashes.

| Paired graph comparison | Before | Prepared query | After / before | Lower after time |
|---|---:|---:|---:|---:|
| `import_graph` | 32.4 ± 1.7 ms | 28.4 ± 0.6 ms | 0.876 (12.4% less time) | 30/30 rounds |
| `reexport_graph` | 27.9 ± 5.2 ms | 27.3 ± 4.2 ms | 0.977 (2.3% less time) | 17/30 rounds |

The import-graph improvement is consistent across this run. The small barrel
mean difference is noisy and does **not** establish a reliable improvement.
This comparison is separate from the full three-compiler run; the measurements
are not averaged together. Before-run load averages were 5.43 / 7.41 / 8.00 on
the shared Apple M3 Pro workstation, after our builds, tests and audits finished.

The checkpoint also records resolved compiler artifacts outside timed commands:
both Home binaries, the actual native TS 7 executable, TS 6's compiler payload
(`lib/_tsc.js`), launchers and Node runtime. The native compiler is distinguished
from its JavaScript launcher. Evidence: `provenance-before.json` and the
checkpoint-local `provenance.py`; automatic harness-wide provenance remains
tracked by [#544](https://github.com/home-lang/home/issues/544).

The complete three-compiler measurement is **`20260828T234350Z`**, on the same
Apple M3 Pro arm64 / macOS 27.0 shared workstation. Verified versions are
**TS 6.0.3 and native TS 7.0.2**; native TS 7/`tsgo` is one competitor. All 19
workloads pass admission before three warmups and 30 rotating-order rounds.
Integrity validation accepts **570 round files / 1,710 successful finite
samples**. No sample is discarded. Fresh generation matches all **513 corpus
files byte-for-byte**, and the recorded compiler/runtime/launcher paths and
hashes match after measurement (`provenance-after.json`).

Our builds, tests and audits had finished before timing; unrelated shared-host
activity persisted. Full-run load averages before/after were 4.89 / 7.16 / 7.89
and 6.37 / 7.56 / 7.94. Times below are mean ± sample standard deviation;
ratios use unrounded means and the faster competitor (native TS 7 in every row).

| Workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `startup` | 65.7 ± 1.2 ms | 40.0 ± 1.1 ms | 3.6 ± 0.1 ms | 11.26× faster |
| `many_files` | 214.6 ± 2.7 ms | 57.2 ± 1.8 ms | 34.8 ± 1.0 ms | 1.65× faster |
| `deep_types` | 132.6 ± 17.7 ms | 53.1 ± 2.5 ms | 27.1 ± 1.1 ms | 1.96× faster |
| `import_graph` | 131.0 ± 2.1 ms | 47.0 ± 1.3 ms | 28.1 ± 1.1 ms | 1.67× faster |
| `reexport_graph` | 102.7 ± 14.8 ms | 42.7 ± 1.3 ms | 25.6 ± 2.5 ms | 1.67× faster |
| `tsx_components` | 167.9 ± 1.9 ms | 48.0 ± 0.9 ms | 23.3 ± 0.2 ms | 2.06× faster |
| `generic_calls` | 182.8 ± 3.2 ms | 56.3 ± 1.7 ms | 23.2 ± 0.4 ms | 2.42× faster |
| `control_flow` | 288.2 ± 93.7 ms | 86.9 ± 35.4 ms | 46.7 ± 11.7 ms | 1.86× faster |
| `type_predicates` | 434.7 ± 102.3 ms | 142.9 ± 87.0 ms | 67.7 ± 15.1 ms | 2.11× faster |
| `type_predicates_large` | 1023.2 ± 72.0 ms | 362.2 ± 30.4 ms | 340.5 ± 18.2 ms | 1.06× lower mean; narrow |
| `null_safe_access` | 187.3 ± 2.2 ms | 57.0 ± 1.8 ms | 39.6 ± 0.4 ms | 1.44× faster |
| `destructuring` | 137.7 ± 2.1 ms | 47.6 ± 1.4 ms | 35.3 ± 0.7 ms | 1.35× faster |
| `overload_resolution` | 196.8 ± 10.6 ms | 63.7 ± 1.8 ms | 29.5 ± 0.7 ms | 2.16× faster |
| `class_hierarchy` | 233.5 ± 135.8 ms | 62.6 ± 39.5 ms | 34.2 ± 18.4 ms | 1.83× faster |
| `structural_objects` | 186.2 ± 11.0 ms | 59.1 ± 4.4 ms | 30.6 ± 1.7 ms | 1.93× faster |
| `interface_composition` | 200.3 ± 5.2 ms | 63.9 ± 1.8 ms | 44.8 ± 1.2 ms | 1.43× faster |
| `variadic_tuples` | 240.3 ± 5.6 ms | 74.8 ± 2.3 ms | 43.1 ± 2.6 ms | 1.74× faster |
| `checkjs_jsdoc` | 200.8 ± 4.6 ms | 53.6 ± 1.3 ms | 37.1 ± 0.6 ms | 1.45× faster |
| `recursive_generics` | 150.7 ± 3.7 ms | 71.1 ± 1.8 ms | 29.1 ± 0.5 ms | 2.44× faster |

Home records lower means on **19/19**. Large predicates lead by only 1.06×
and win 29/30 paired rounds. Small predicates and class hierarchy also win
29/30; every other row wins 30/30. Control-flow, small-predicate and class rows
show substantial variance. These observations are not universal or statistically
established leadership: real projects, other platforms and the outstanding
CommonJS/global/owner/diagnostic gaps remain unvalidated. Earlier checkpoints
and their losses stay documented separately.

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/commonjs-query.hyU20d/release-v1/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T234350Z
```

Console/report evidence: `commonjs-query.hyU20d/timing-v1.log` and
`report-v1.md`; unchanged input verification: `corpus-verified-v1.log`.

The independent large-predicate confirmation **`20260828T234818Z`** uses the
same frozen compiler and unchanged admission gates, three warmups and 30
rotating-order rounds. All **30 round files / 90 successful finite samples**
validate. Home has the lower time in **30/30 paired rounds**; the margin is
still modest. This confirmation is separate, not pooled with or substituted
for the full-run row:

| Confirmation workload | TS 6.0.3 | Native TS 7.0.2 | Home | Home vs fastest competitor |
|---|---:|---:|---:|---:|
| `type_predicates_large` | 1111.8 ± 54.4 ms | 388.5 ± 16.7 ms | 358.6 ± 11.7 ms | 1.08× faster |

```sh
HOME_TSC="$PWD/bench/vs_tsgo/results/commonjs-query.hyU20d/release-v1/bin/home-tsc" python3 bench/vs_tsgo/run.py cold --runs 30 --warmup 3 --workload type_predicates_large
python3 bench/vs_tsgo/compare.py bench/vs_tsgo/results/20260828T234818Z
```

The console record is `commonjs-query.hyU20d/confirmation-v1.log`.
`provenance-confirmation.json` verifies that all recorded artifact hashes still
match the pre-measurement snapshot. Raw full-run and confirmation JSON remain
in their separately named directories under `bench/vs_tsgo/results/`.
