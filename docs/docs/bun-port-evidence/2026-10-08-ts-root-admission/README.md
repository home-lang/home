# TypeScript conformance root-file admission

This checkpoint ports the pinned TypeScript harness distinction between files
passed to the compiler as roots and files merely present on its virtual
filesystem. Home previously added almost every code-bearing virtual section to
the program. That could admit declarations and globals which the fixture had
deliberately left unreachable.

The reference is nested TypeScript pin
`5848bc5157b22ff7f4e3369f4645a514a433b15f`:

- `src/testRunner/compilerRunner.ts` builds `toBeCompiled` and `otherFiles`;
- without a tsconfig, all units are roots unless `noImplicitReferences`, a
  `require(` call, or a triple-slash path reference makes only the last unit a
  root;
- with a tsconfig, only its parsed `fileNames` become compiler inputs;
- `src/harness/harnessIO.ts` mounts both groups in the virtual filesystem but
  passes only `toBeCompiled` to `compileFiles`.

Home now applies those rules before populating `ts_program.Program`. Direct
virtual tsconfigs derive roots from additive `files` entries and
`include`/`exclude` discovery, with case-insensitive fixture paths, TypeScript
input extensions and their upstream priority groups, `allowJs`, default
package-directory exclusions, and output-directory exclusion. Files outside
the root set remain mounted for resolver and import-closure loading. Imported
diagnostics retain the fixture's original filename and directive-line offset.

Two adjacent input defects were removed at the same boundary. Empty
`@filename` sections now remain real harness units. UMD globals are no longer
collected from every declaration on the virtual disk; `ts_program` derives them
from the reachable program graph. A configured root which is missing or has an
unsupported shape produces a retained failed case rather than silently
falling back to a different source buffer.

## Guarded verification

All substantial commands ran serially through `scripts/run-bounded.pl` with
`HOME_RUN_MAX_MB=3840`.

- Root-selection controls pass for all-files mode, each last-file-only trigger,
  empty virtual units, direct tsconfig `files`, `include`/`exclude`, `allowJs`,
  extension priority, case-insensitive paths, and retained missing-root failure.
- An independent program control places a definite type error in an
  unreferenced file; the clean last root passes while the erroneous file stays
  mounted but uncompiled.
- The focused `program` unit-test filter passes, peaking at 1,968 MB.
- Pinned real fixtures `packageJsonMain_isNonRecursive`,
  `importTypeNestedNoRef`, and `umd2` pass **3/3**, peaking at 1,946 MB.
- The named local category gate remains **87/87**, peaking at 1,954 MB.

No complete-corpus result is claimed from this focused checkpoint. The earlier
complete package timeout remains a non-result. [#841](https://github.com/home-lang/home/issues/841)
stays open for inherited config expansion, real default-library/compiler-API
inputs, and faithful unsupported/skip accounting. Complete corpus evidence
remains open in [#832](https://github.com/home-lang/home/issues/832), and full
Bun acceptance remains open in [#66](https://github.com/home-lang/home/issues/66).
