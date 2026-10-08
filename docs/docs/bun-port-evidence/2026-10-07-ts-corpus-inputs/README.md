# Compiler inputs and real declaration files

Compiler options and diagnostic filenames no longer come from expected
diagnostic contents. The pinned TypeScript 7 `GetStrictOptionValue` defaults
strict-family flags on unless explicitly disabled. Home now applies that
default consistently and layers actual tsconfig options, harness directives,
and selected variant options over it. Boolean variant parsing is confined to
the filename's option list. An expected header cannot rename an actual file.

The any-exporting absolute package declaration substitutes are removed.
Missing inputs remain missing. The upstream `/.lib` mount now uses the real
nested TypeScript `tests/lib` bytes, including files loaded as explicit
`libFiles` roots. Library imports, absolute package types and global declarations
retain their real types. Both compilation paths preserve the selected
`skipLibCheck` policy; application diagnostics remain visible.

Six final controls pass, including strictness/config/variant layering, mutated
expected-header invariance, missing declaration rejection, physical library
type preservation and explicit declaration-check policy. Ten independent
survey controls pass. The two unchanged type-only regression fixtures remain
2/2 exact matches. The final leading 200-case exact survey measures **166 passes,
34 failures, zero skips**, exits 1, and peaks at 357 MB. All failed names and
raw diffs are retained. These observations replace the earlier 172/200 prefix
for the corrected input policy; neither result is a full parity claim.

The full normal conformance attempt was stopped by the unchanged **3,840 MB**
runaway ceiling and exited 125. It produced no complete aggregate. This attempt
used the intermediate input-mount/configuration build before the final
library-policy wiring. Its process sample shows repeated generic substitution
while checking real React declarations in the baseline-aware survey. The
driver still eagerly checks declarations before filtering diagnostics for
`skipLibCheck`; that work is tracked in [#842](https://github.com/home-lang/home/issues/842).
The unsuccessful run, process sample and intermediate compilation probes are
retained alongside the successful controls.

The source change is confined to the conformance harness. Production compiler
sources are unchanged from the preceding checkpoint; this batch does not
claim a new standalone-compiler or Zod run. Source, binary, library and artifact
hashes are in `manifest.json`. No upstream case, baseline, skip, TODO, deadline
or ratchet ceiling was modified. Every heavy command used the normal lock and
3,840 MB limit.

Full variant execution, source-file inclusion, real default-library/compiler
API inputs and the complete applicable Bun acceptance run remain open in
[#841](https://github.com/home-lang/home/issues/841),
[#832](https://github.com/home-lang/home/issues/832) and
[#66](https://github.com/home-lang/home/issues/66).
TypeScript controls earn no original Bun test-case credit.
