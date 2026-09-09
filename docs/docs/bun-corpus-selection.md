# Native corpus selection

The native selection modules port the file-selection contracts in `scripts/runner.node.mjs` at Bun `4982b91e3702094330f3be3883354c52b8c01323`. Selection records describe coverage; they do not represent passing tests. Full CI setup and execution remain tracked in [#724](https://github.com/home-lang/home/issues/724), under [#66](https://github.com/home-lang/home/issues/66).

`corpus_selection.zig` parses expectation filenames, modifiers, values, comments, and original line numbers. The pinned runner excludes matching entries regardless of whether their value is `FAIL`, `FLAKY`, `SKIP`, or another label. Modifiers match with OR semantics and case-sensitive equality. Filename rules use normalized-path substring matching, including the upstream removal of the first `test/` occurrence. They are not globs.

Selection applies the macOS x64 CI Node-file classification rule, optional Node-only filtering, comma-separated includes/excludes, applicable expectations, positional filters, and sharding in upstream order. Positional filters take precedence over sharding. Modified tests receive stable priority after selection. The acceptance API does not offer random smoke sampling.

Call `corpus_runner.runGateWithOptions` with a `SelectionPolicy` to apply these rules to native execution. The policy carries explicit platform/build context, original expectation source bytes, optional Home expectation source bytes, and filter/shard options. A Home-only exclusion fails before any child starts. Removing an upstream exclusion is permitted and recorded as additional Home coverage. Explicit file, directory, and named-subset runs preserve their requested paths.

When persistence is enabled, a `selection` journal event records the complete discovery inventory, ordered selected indices, excluded indices and reasons, expectation metadata and source hashes, effective modifiers, additional Home coverage, and the execution range. The selected/excluded sets must partition the inventory. Start/limit applies after selection; files outside that range remain visible in the policy record. The outcome validator rejects an execution selection that disagrees with this record. Exclusions do not increase registered skip or pass counts.

`corpus_vendor.zig` implements vendor filename selection and recursive discovery. It uses Home's native ECMAScript regular-expression engine for upstream `skipTests` patterns: `*` becomes `.*`, while other regex syntax remains active. Explicit `testExtensions` bypass ordinary test classification and `skipTests`, as in the pinned runner. Recursive entry order, filename filters, skip reasons, and project defaults remain distinct from installation and execution outcomes.

For differential selection audits, compile `packages/home_test/src/corpus_selection_probe.zig` as a native executable and pass input/output JSON paths. Its `Input` type defines the file inventory, original/Home expectation text, and context/options pairs. Output files are created exclusively and labeled `selection-only`. This diagnostic does not execute JavaScript or award corpus pass credit.

The default corpus CLI has not yet been connected to complete CI orchestration. Callers of the selection API currently supply platform context; native platform discovery, expected-agent checks, original root/test installation, services, vendor checkout preparation, and a unified setup/execution journal remain unfinished. The Elysia checkout under `packages/runtime/test/vendor/` is generated data and is ignored by Git. Its pinned source revision and setup evidence must be retained when evaluating the complete suite.

## Verified checkpoint, 2026-09-08

The native build passes 23/23 steps and the native corpus harness passes 15/15 tests. Standalone selection/discovery checks pass 14/14 and the outcome validator passes 10/10. A native probe matches the unchanged pinned JavaScript functions across eight platform/build contexts and eight filter/shard configurations: 304,256 include/exclude decisions over the 4,754-file inventory. These are selection comparisons, not native execution on eight platforms or passing corpus cases.

Elysia tag `1.4.28` resolves to `56310be9617b826f862c985eae95ae823d95f097`. Native discovery matches all 208 recursive directory entries in order and selects the same 129 files. The original `ws/connection.test.ts` exclusion remains separate. Home installs 218 packages and runs the unchanged Elysia build script successfully, with original 180-second install and 60-second build deadlines. The `bun`, `node`, and `home` command aliases all resolve to the same Home executable, SHA256 `716f39bd45568c3cab84f080aafc32d9ec553452ba5d5945ec348e289e40bbc2`.

Installation updates one stale lockfile field: the root `exact-mirror` peer range changes from `^0.2.6` to the package manifest's existing `>= 0.0.9`. A separate pinned Bun installation produces the identical resulting lockfile, byte for byte. All other 282 tracked vendor files remain unchanged. The strict first integrity result remains recorded as false for the lockfile change; the separate control establishes why it is the expected installation result. No lockfile, test, or snapshot was manually edited to obtain that result.

The first harness run retained two regex interpreter traps and a selection fixture missing its required inventory manifest. Native regex initialization now uses Home's normal once-guarded JSC startup, and the fixture declares its inventory. The first comparison also retained a Python-version incompatibility and an incorrect reference calculation that confused shard movement with newly unexcluded coverage. Corrected comparisons pass. [First evidence](./bun-port-evidence/2026-09-08-selection-first/manifest.json) and [verified evidence](./bun-port-evidence/2026-09-08-selection-verified/manifest.json) preserve source snapshots, full inventories, raw logs, hashes, and the separate setup control.

That selection/setup checkpoint did not execute vendor tests or award case pass credit. The subsequent execution checkpoint below records those outcomes separately.

## Prepared vendor execution, 2026-09-08

From the repository root, run a vendor already checked out, installed and built at its pinned tag:

```sh
zig-out/bin/home test --bun-corpus-prepared-vendor elysia
```

Optional trailing positional strings filter filenames using the pinned vendor rules. The CLI checks that Git HEAD resolves to the manifest tag before executing. It does not clone, install or build; its journal explicitly records `execution: "prepared-vendor"` and `setup_performed: false`. Prior setup evidence is required when evaluating the complete suite.

`corpus_runner.runPreparedVendorWithOptions` discovers and journals the complete vendor inventory before launching any selected file. Each file runs through Home in the vendor's working directory with normal project configuration discovery and upstream vendor test mode. Alternate test runners use the pinned preload path. Vendor files ignore Node `// Flags:` comments, and serial execution removes inherited `TEST_SERIAL_ID`, matching the pinned runner. Source validation uses the path relative to the overall corpus project. Ordinary assertion failures are retained and later files still execute. Original per-file deadlines and complete child/output ownership apply.

The native build passes **23/23 steps and 17/17 harness tests**; outcome-validator controls pass **11/11**. The new private controls verify project configuration, custom test directories and extensions, serial environment, and a real failure followed by a successful file.

All **129 pinned-selected Elysia files completed in one attempt: 1,516 passing registered cases, zero failing cases, zero registered skips and zero TODOs**. The original `ws/connection.test.ts` exclusion remains an inventory exclusion and earns no pass or skip credit. No path filter or range limit was used. All 129 captures reached verified EOF; the separate validator checked raw stdout/stderr and JUnit hashes and every registered case. Home SHA256 is `19e41223c7fc2d2dcda763470fcc84570900db08b4d547340bdae5286d42bc98`.

All 283 tracked vendor files retained their post-install hashes during execution, including the separately verified lock normalization described above. The setup was performed by the preceding Home build (`716f39bd…`); execution used the new `19e41223…` build. This is a prepared-project execution checkpoint, not a fresh end-to-end CI setup run. [Execution evidence](./bun-port-evidence/2026-09-08-vendor-execution/manifest.json) retains the source snapshots, build and validator results, full per-file reports, selection and integrity checks. Generated obsolete object cleanup removed 371,467,160 bytes.

The full primary corpus, native platform verification, remaining runtime features and complete CI orchestration are still open under #66 and #724.
