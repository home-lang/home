# TypeScript virtual `tsconfig` inheritance

This checkpoint replaces the conformance adapter's single-file
`tsconfig.json` parse with expansion of the config graph mounted by the
fixture. The executable inputs now follow the pinned TypeScript runner rather
than silently dropping inherited options.

The reference pins are TypeScript-go
`89d5d5b2849a0db0957065889ca58536fa6d2e4a` and nested TypeScript
`5848bc5157b22ff7f4e3369f4645a514a433b15f`.

Implemented here:

- string and array `extends`, merged left-to-right before the child;
- relative, absolute, extensionless, and directory config paths;
- package export wildcard targets, package `tsconfig` fields, and package
  default `tsconfig.json` files;
- cycle detection and retained failures for missing or invalid parents;
- rebasing inherited `files`, `include`, `exclude`, output directories,
  `rootDirs`, and `typeRoots` to the declaring config;
- inherited strict/checking flags, `allowJs`/`checkJs`, module settings,
  `baseUrl`, `paths`, type roots, and root-file selection;
- family-qualified fallback baseline roots, so an absent tsgo-generated
  baseline consults the matching pinned TypeScript `compiler` or
  `conformance` directory instead of the parent directory;
- explicit JSON package-export targets remain resolvable after the resolver
  partitions its extension passes.

The first matching virtual `tsconfig.json` remains the project config. This is
intentional and matches `harnessIO.ts`, which walks fixture units in order,
parses the first `tsconfig.json`/`jsconfig.json`, removes that unit, and leaves
the remaining files mounted for config and module resolution.

## Guarded verification

Every substantial command ran serially through `scripts/run-bounded.pl` with
`HOME_RUN_MAX_MB=3840`.

- Virtual-config controls pass **10/10**, covering merge order, path rebasing,
  package exports, package config defaults, inherited paths, missing parents,
  and cycles; peak 287 MB on the final run.
- Focused inherited-config and retained-missing-parent integration controls
  pass; observed peaks were 2,139 MB and 2,149 MB.
- The complete `ts_resolver` package passes after the JSON extension fix;
  peak 237 MB.
- Pinned compiler fixtures pass **4/4**:
  `configFileExtendsAsList`, `tsconfigExtendsPackageJsonExportsWildcard`,
  `pathMappingInheritedBaseUrl`, and `pathMappingWithoutBaseUrl2`; peak
  2,037 MB.
- Pinned conformance fixtures `verbatimModuleSyntaxCompat3` and
  `verbatimModuleSyntaxCompat4` pass **2/2**; peak 1,988 MB.
- The named local category regression remains **87/87**; peak 2,113 MB.

An initial pinned compiler run was **3/4**: the inherited `baseUrl` diagnostic
was produced correctly, but the fallback helper looked one directory above
the `compiler` baseline family and therefore expected zero diagnostics. The
family root was corrected; no baseline or expected diagnostic was changed.

This is a focused input-fidelity checkpoint, not a complete-corpus result.
[#841](https://github.com/home-lang/home/issues/841) remains open for real
default-library/compiler-API inputs, null-override and config-diagnostic edge
cases, and faithful unsupported/skip accounting. Complete TypeScript corpus
evidence remains in [#832](https://github.com/home-lang/home/issues/832), and
full Bun acceptance remains in [#66](https://github.com/home-lang/home/issues/66).
