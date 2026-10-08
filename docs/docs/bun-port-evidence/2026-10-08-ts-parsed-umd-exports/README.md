# Parsed UMD namespace exports

Published source: [30ab18c8c](https://github.com/home-lang/home/commit/30ab18c8c).

The parser previously erased `export as namespace` into an empty block without
retaining its name. Checker and Program independently scanned raw text for the
form. Those scans accepted comments, strings and nested invalid declarations,
missed comments between tokens and escaped identifiers, and repeatedly rescanned
large declaration files for ordinary type references.

HIR now retains each parsed declaration's decoded name, source node, top-level
scope and external-module indicator alongside its erased runtime representation.
Checker lookups use these facts and cache exact positive and negative results by
name, source root and virtual-file restriction. Source attachment, declaration
mode and importer-path changes invalidate the cache. Program collection uses the
same parsed facts from prepared sources and excludes non-declaration files,
redirects, nested forms and scripts without a real module indicator. Dynamic
import expressions do not promote declaration-only scripts into modules.

The new checker controls retain two negative failures against the prior scanner;
Program retains 242 pass / 1 fail. An initial implementation has a retained
container-declaration compile failure and no executed tests. Final focused
checker controls pass 6/6, including comment/string exclusions, decoded names,
token trivia, declaration-context invalidation, repeated negative lookups,
virtual-file boundaries and `noImplicitReferences` behavior. The parser selection
passes 1,065/1,065 tests and Program 243/243. Initial test-setup mistakes were
corrected before the functional negative runs; their outcomes earn no case credit.

The pre-integration tree passes checker 4,524/4,524, driver 200/200, opt-in
controls 3/3 and all ten survey admission/mismatch controls. Its compiler builds
at 2,938 MB. Pinned 106-file Zod retains 195 TS diagnostics and three HM9002
recoveries at 526 MB; its ceiling and normalized diagnostics are unchanged.
Zod is not a passing project. Program's successful gate precedes only additional
checker/parser test controls; production semantics are the same at that stage.

The first original React attempt is deliberately interrupted with exit 130 to
validate the concurrent require-binding index together with this source. It
starts `intraExpressionInferencesJsx`, leaves
`contextuallyTypedStringLiteralsInJsxAttributes02` unstarted and earns no complete
aggregate or passing-case credit.

After require-binding integration, source 30ab18c8c passes checker 4,526/4,526,
driver 200/200, Program 243/243, opt-in controls 3/3 and all ten survey controls.
Its compiler builds at 2,915 MB; Zod retains 195 TS diagnostics and three
recoveries at 545 MB, with normalized output unchanged.

The integrated original React selection exits 125 at observed tree footprint
3,874 MB against the unchanged 3,840 MB ceiling. The first fixture is unfinished
and the second unstarted. There is no complete aggregate or passing-case credit.
A sample at about six minutes shows `Program.importProgramGlobals` through owner
import, checked transfer and type-transfer materialization, including repeated
mapped argument allocation/free. It samples 2.1 GB physical footprint; this is
not the final peak. A later sample attempt finds the process already terminal
and produces no sample. These observations identify the sampled transfer phase,
not a controlled performance comparison or proof of complete graph correctness.

Original fixtures, declarations, expected diagnostics, skips/TODOs, the
900-second deadline, normal lock and resource ceilings remain unchanged. Exact
source stages and artifact hashes are recorded in the manifest. The preceding
relation-service measurement's terminal 900-second timeout and late UMD scan
sample are retained in its evidence directory. Graph/declaration-policy work
remains open in [#842](https://github.com/home-lang/home/issues/842), input fidelity
in [#841](https://github.com/home-lang/home/issues/841), complete corpus acceptance
in [#832](https://github.com/home-lang/home/issues/832), and full Bun parity in
[#66](https://github.com/home-lang/home/issues/66).
