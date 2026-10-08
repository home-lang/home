# Substitution binders and per-file syntax

Repeated generic substitution created fresh callable binders while attaching
member-predicate metadata. The receiver predicate could therefore refer to a
different binder from its actual signature. Metadata now follows the rebuilt
signature when it originated there; receiver-specific predicates still use
their own substitution path. Member types are reused for metadata instead of
being traversed twice. Signature constraints/defaults share the incoming memo
until their local substitution map actually changes.

Declaration files under an explicit `skipLibCheck` retain inherited members and
checked type metadata while skipping diagnostic-only interface relation passes.
Application files remain validated, and syntax diagnostics remain visible.
Other declaration processing still runs; this is not a claim that the full
reference compiler's lazy declaration-check policy is complete.

The original React run exposed JSX parsing being propagated from a `.tsx` root
to every dependency. Program checking and cached emit now use each source
filename's syntax mode. Mixed `.ts`, `.d.ts` and `.tsx` controls retain generic
arrow parsing, declaration comments and real JSX emission. A subsequent parser
fix accepts contextual-keyword names such as `object` in type predicates and
assertions while preserving ordinary return types.

Before the final parser change, the two unchanged original React cases complete
under the existing limits but report 0/2 exact matches. Correct per-file syntax
reduces their observed peak from 3,597 MB to 154 MB and exposes concrete syntax
and JSX/type mismatches. Failed comparisons remain failures. The first baseline
attempt was stopped by the critical disk floor; an intermediate run with a
known predicate-binder bug was intentionally interrupted and retained. Neither
attempt produced passing-case credit.

Pre-integration gates are recorded in `manifest.json`: checker 4,486/4,486,
driver 198/198, program 229/229, parser and precedence 905/905, substitution
controls 4/4 and declaration controls 3/3. Their exact source stages are
qualified in the manifest. The leading corpus remains 166/200, 34 failures,
zero skips. The standalone compiler builds and the Zod recovery ceiling stays
three. Zod retains 196 TS diagnostics and three HM9002 warnings, but its text
changed from the preceding checkpoint; that diff is retained. This does not
establish a passing Zod project.

Only inactive generated test/build caches and regenerable download/HTTP caches
were reclaimed. Source files and pinned Bun/WebKit artifacts were preserved.
Admission refusals and interrupted runs are retained. All heavy commands use the
normal lock, disk floors and 3,840 MB ceiling. Original cases, declarations,
baselines, skips, TODOs and deadlines are unchanged.

Remaining exact React behavior and declaration work stay open in
[#842](https://github.com/home-lang/home/issues/842), with compiler-input fidelity
in [#841](https://github.com/home-lang/home/issues/841). Complete TS corpus and
Bun acceptance remain open in [#832](https://github.com/home-lang/home/issues/832)
and [#66](https://github.com/home-lang/home/issues/66).

After integration with origin/main export-owner reuse, the combined source
passes checker 4,486/4,486, driver 198/198, program 231/231 and parser/precedence
905/905. The standalone compiler builds at 3,036 MB peak. Zod stays at 196 TS
diagnostics and three recoveries, with output equal to the pre-integration
substitution build. Ten real corpus-survey controls pass.

The final contextual-predicate React attempt stops at the unchanged 3,840 MB
ceiling while processing `intraExpressionInferencesJsx`; the second selected
case is unstarted. The integrated leading 200-case remeasurement similarly
stops at that ceiling on `multiline.tsx`. Neither run yields a complete
aggregate or passing-case credit. The earlier 166/200 count is historical to
the pre-predicate source stage. A retained process sample places the integrated
work in `collectProgramCommonJsExports` calling `moduleExportAssignmentInfo`,
which recompiles and fully checks a declaration owner during export discovery.
These source-owner and semantic-resolution costs remain open under #842.

The latest source includes the subsequently published nested-owner reuse on
origin/main. Its program suite passes 232/232, its compiler builds at 3,036 MB
peak, and Zod remains at 196 TS diagnostics and three recoveries at 632 MB.
The latest source stage and diagnostic comparison are recorded separately in
the manifest. Original-case resource stops are retained at their tested stages;
no successful full-corpus remeasurement is claimed for this latest tree.
