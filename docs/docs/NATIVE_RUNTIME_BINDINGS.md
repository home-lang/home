# Native runtime binding ownership

Home's JSC-enabled build still links most C++ bindings and vendor libraries from a configured local Bun build. A successful build is not evidence that every runtime component has been ported into Home.

`BunProcess.cpp` is now compiled from Home's source at `packages/runtime/upstream/src/jsc/bindings/BunProcess.cpp`. The corresponding external object is excluded from linking. This makes changes such as the corrected `process.config.variables.v8_enable_i18n_support` field effective in the main runtime, workers, and the native test runner.

## Build and dependencies

Run `zig build debug -Denable_jsc=true`. The existing `HOME_BUN_OBJ_ROOT` and `HOME_BUN_WEBKIT_LIB` overrides still select the external native artifacts.

For the Home-owned process binding, the build requires `compile_commands.json` next to the external `obj` directory and its `BunProcess.cpp` entry. It uses that entry's compiler, ABI flags, generated headers, and dependency include paths. Missing metadata is an error, not a fallback to the stale external process object.

The source is copied into the build cache so quoted includes use the ABI-matched external headers. Saved precompiled headers are not reused: they may belong to another compiler version. The original `root-pch.h` is parsed instead. Clang's dependency file tracks all included headers, and Home's build cache tracks the implementation and compiler arguments. Source/header changes therefore rebuild the owned binding; unchanged builds reuse it.

This is incremental binding ownership, not an independent C++ runtime build. Moving the remaining bindings, generated headers, and vendor build inputs into Home remains part of [the full Bun port](https://github.com/home-lang/home/issues/66).

## Builtin module ownership

The native build also compiles Home's `InternalModuleRegistry.cpp` and regenerates the `node:url` builtin from `packages/runtime/upstream/src/js/node/url.ts`. The corresponding external unified object is excluded. Its other C++ implementations are rebuilt from their ABI-matched external sources; they are not yet Home-owned.

`build-support/bundle-native-modules.ts` has an explicit ownership manifest. Only the listed module literals are replaced; all other builtin literal bytes remain those of the configured native build. Bun is currently a build-time TypeScript bundling dependency. The resulting private JSC builtin source is embedded in Home, not loaded from Bun or delegated to a Bun process at runtime.

Home's incomplete source mirror can have different numeric module IDs from the external native build. Generation resolves each referenced module by identity, maps it to the linked registry's enum, and validates each native factory against the linked dispatch table. It also checks the complete Home error-code numbering against the native error enum. Missing mappings, unsupported wrapped/Zig native calls, unvalidated class IDs, and missing or duplicate replacement literals fail the build instead of silently using stale code. This incremental path does not yet support every builtin; expanding that ownership remains part of #66.

Generated files stay in Home's build cache. The generator does not write into either source tree or modify the external build's generated headers. Compiler depfiles track the external sources and headers used by the rebuilt translation unit.

The generator uses explicit ESM input files so Home's CommonJS package setting cannot wrap a builtin as a module. Leftover import/export syntax is a build error. Native builds using `BUN_DYNAMIC_JS_LOAD_PATH` are rejected because loading external JavaScript from disk would bypass the embedded Home implementation. Bun and C++ compiler executables are cache inputs, so replacing either tool invalidates the associated generated output.

## Checks

- `zig build test -Dfilter=native-bindings` tests compile-command selection and argument normalization.
- `bun test build-support/native_module_abi.test.ts` tests module/native ABI mapping and rejection of missing, ambiguous, or unsupported entries.
- `bun test build-support/bundle-native-modules.test.ts` verifies actual generation inside Home's CommonJS package, complete function grammar, unchanged non-owned literals, and rejection of deliberate error-ABI drift. These integration checks skip explicitly when native build artifacts are unavailable.
- `HOME_NATIVE_VM=1 zig-out/bin/home-debug run tests/runtime/native-url-contracts.test.mjs` exercises the embedded URL implementation, including option combinations, serialization delimiters, IDNA, and legacy IPv6 behavior. The exact upstream fixtures are tracked in [#458](https://github.com/home-lang/home/issues/458).
- `HOME_NATIVE_VM=1 zig-out/bin/home-debug run tests/runtime/native-intl-capabilities.test.mjs` verifies capability metadata and real Intl/IDNA behavior in main, worker, and test-runner contexts.
- Native corpus skips and commented-out test bodies remain unsupported coverage, never passing feature checks. Related follow-up: [#456](https://github.com/home-lang/home/issues/456).

### URL port checkpoint

The exact upstream `test-url-format-whatwg.js`, `test-url-format.js`, and `test-url-parse-format.js` fixtures pass through Home's native corpus runner. A concurrent audit of the 169 routed Node-core fixtures reports **157 passing files, 12 unsupported files, 0 failures** (231 passing checks, 12 unsupported checks). The unsupported set still includes explicit upstream skips and the fully commented experimental-warning fixture; this is not 100% suite parity.

The six `tests/runtime/native-*.test.mjs` regressions pass, including the new URL test. The URL test was also run against the old binary and failed as expected, proving it detects a stale builtin. Five build-time generator/ABI tests and three Zig binding-helper tests pass; an unchanged native rebuild reuses all owned artifacts.

For the outer corpus audit, leave `HOME_NATIVE_VM` and `HOME_CORPUS_FULL_VM` unset. The CLI currently treats any nonempty value, including `"0"`, as enabling those overrides; the corpus runner sets the required native child environment itself.
