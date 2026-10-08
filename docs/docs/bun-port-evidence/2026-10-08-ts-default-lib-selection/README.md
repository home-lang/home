# TypeScript default-library selection

This checkpoint corrects the library filename selected by `ts_program` for
[#841](https://github.com/home-lang/home/issues/841). The previous table used
`lib.es2024.d.ts` when the target was unspecified, `lib.es2015.d.ts` for
ES2015, and non-`full` entry points for later targets. None of those names
match the native runner pinned in this repository.

The authoritative source is `typescript-go` commit
`89d5d5b2849a0db0957065889ca58536fa6d2e4a`, specifically
`internal/tsoptions/enummaps.go` and `CompilerOptions.GetEmitScriptTarget`.
At that pin, an unspecified target is `LatestStandard` (ES2025), and the
default library table is:

| Effective target | Selected entry point |
| --- | --- |
| unspecified / ES2025 | `lib.es2025.full.d.ts` |
| ES3 / ES5 | `lib.d.ts` |
| ES2015 | `lib.es6.d.ts` |
| ES2016–ES2024 | matching `lib.es20xx.full.d.ts` |
| ESNext | `lib.esnext.full.d.ts` |

Home now resolves an exact library filename rather than manufacturing every
default as `lib.<target>.d.ts`. Explicit `compilerOptions.lib` entries keep
their existing `lib.<name>.d.ts` resolution path.

## Guarded verification

Every substantial command ran serially through `scripts/run-bounded.pl` with
`HOME_RUN_MAX_MB=3840`.

- the complete `ts_program` package passed, including an exhaustive table for
  all 14 target enum values plus the unspecified-target case and end-to-end
  checks for explicit target, unspecified target, explicit `lib`, and `noLib`;
  peak tree footprint was 2,110 MB and host low-water was 30%;
- targeted Pickier, `zig fmt --check`, and `git diff --check` passed;
- the exact cached `@stacksjs/bunpress` 0.2.17 CLI built all **112 pages**;
  peak tree footprint was 219 MB and host low-water was 32%.

No fixture, baseline, expected diagnostic, or resource limit changed. This is
the program-selector boundary only: mounting the pinned bundled declaration
files into every applicable conformance run remains open in #841, and this is
not a complete-corpus claim.
