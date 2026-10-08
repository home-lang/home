# TypeScript upstream unsupported-option accounting

This checkpoint ports the dynamic compiler-option skip boundary from the
pinned `typescript-go` compiler runner for
[#841](https://github.com/home-lang/home/issues/841). Unsupported configured
variants remain part of the corpus and contribute to the total, but are
reported as skipped before compilation. They can no longer receive pass credit
from Home compiling them with a different or incomplete option surface.

The authoritative behavior is
`internal/testutil/harnessutil.SkipUnsupportedCompilerOptions`, called by
`internal/testrunner/compiler_runner.go` after the runner has built the final
compiler options for a configured case. Home now applies the same ordered
classification after virtual-tsconfig inheritance and selected matrix
overrides:

- module kind AMD, UMD, or System;
- module resolution Node10 (including the `node` alias) or Classic;
- explicit `esModuleInterop: false`;
- explicit `allowSyntheticDefaultImports: false`;
- a non-empty `baseUrl`;
- a non-empty `outFile`;
- target ES5;
- explicit `alwaysStrict: false`.

The reason is retained on each loaded corpus entry and converted to an
ordinary skipped result by the same runner path that counts passes and
failures. Classification preserves the upstream priority order, and inherited
options are included rather than inspecting source directives alone.

## Guarded verification

Every substantial command ran serially through `scripts/run-bounded.pl` with
`HOME_RUN_MAX_MB=3840`.

- all eight classifier reasons, supported controls, priority order, and an
  inherited-`baseUrl` control: **2/2** Zig tests passed; peak 309 MB;
- real directory loading plus execution of an ES5/ES2015 target matrix:
  **2/2** Zig tests passed, producing exactly one pass, one skip, and zero
  failures; peak 1,985 MB;
- existing multi-option directory-loader regression: **2/2** Zig tests passed;
  peak 327 MB;
- named local category regression: **87/87** configured cases passed with zero
  failures and zero skips; peak 2,050 MB.

No source fixture, expected diagnostic, or resource limit was changed. The
unfiltered conformance package was not rerun: the preceding checkpoint already
established that it exceeds the 3,840 MB ceiling, so repeating that
inconclusive run would add memory pressure without stronger evidence.

This is not a complete-corpus claim. This checkpoint covers the pinned
runner's dynamic `SkipUnsupportedCompilerOptions` policy only. Its static
disabled-fixture list, faithful unsupported-case discovery outside this
function, default-library inputs, and remaining compiler-API parity stay open
in #841. Full Bun acceptance remains tracked in
[#66](https://github.com/home-lang/home/issues/66).
