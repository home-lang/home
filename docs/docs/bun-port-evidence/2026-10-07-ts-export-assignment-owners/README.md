# Declaration export-assignment owners

Source: [51db032e9](https://github.com/home-lang/home/commit/51db032e9).
Compiler and upstream pins, source hashes and artifact hashes are retained in
`manifest.json`.

Declaration CommonJS export discovery previously called the full single-file
compiler to inspect `export =` and its value annotation. This reparsed and
checked a declaration that Program had already retained. A process sample from
the preceding checkpoint placed a memory-limited real React corpus run in this
duplicate declaration check.

Discovery now reads the retained compilation's syntax. The independent source
query prepares syntax without semantic checking, and the conformance resolver
uses its retained module owner instead of reading and recompiling each request.
Private type names remain allocator-owned. The query preserves `any`, exported
types, absent assignments and source-trivia behavior.

Program still checks declarations during normal compilation. A control checks
that discovery preserves the bound owner, then normal compilation checks that
same owner and reports a genuinely missing declaration type. The complete
Program suite passes 234/234 under the unchanged 3,840 MB ceiling, with a
2,043 MB observed peak. Retained resolver controls pass 4/4 and opt-in runner
controls pass 3/3. Their results are recorded separately in the manifest.

All ten survey admission/mismatch controls pass. The standalone compiler builds
at 2,866 MB observed peak. The pinned 106-file Zod corpus retains 196 TS
diagnostics and three HM9002 recoveries at 596 MB; the recovery ceiling remains
three. Its diagnostics equal the preceding checkpoint after normalizing only
the temporary corpus directory. This is a recovery check, not a passing Zod
project. An initial compiler admission attempt expired while waiting for the
machine lock, before compilation began; a retry with identical limits succeeds.

The two unchanged original React cases were requested under their original
900-second deadline. The first, `intraExpressionInferencesJsx`, stops at
3,844 MB against the unchanged 3,840 MB ceiling, with supervisor exit 125.
The second, `contextuallyTypedStringLiteralsInJsxAttributes02`, is unstarted.
There is no complete aggregate and no passing-case credit. The retained process
sample now places the work in normal `Program.compileAll` declaration checking,
inside member lowering and generic substitution, rather than the removed export
discovery check. These remaining semantic costs are unresolved.

Original fixtures, declarations, expected diagnostics, skips, TODOs and test
deadlines remain unchanged. These changes remove duplicate syntax-query work;
they do not establish complete declaration semantics or full Bun parity.
Remaining declaration and substitution work is tracked in
[#842](https://github.com/home-lang/home/issues/842); full corpus and Bun
acceptance remain open in [#832](https://github.com/home-lang/home/issues/832)
and [#66](https://github.com/home-lang/home/issues/66).
