# Native VM context option snapshots

This checkpoint implements #890, following the flag-default and exception-propagation fix in #889. It contributes to #66 and leaves the broader VM lifetime work in #885 open.

`createContext` now reads `name`, `origin`, `codeGeneration`, `microtaskMode` and `importModuleDynamically` once in that order before validation. Ordinary property reads preserve Proxy `get` behavior without adding `has` operations. The redundant facade-level microtask read/validation was removed. Earlier getter results are traced through a scoped `MarkedArgumentBuffer` while later getters execute, including when a getter invokes full GC.

The parser validates names/origins, code-generation object/flags, microtask mode and importer in Node's order. It rejects arrays and callable objects as context options or code-generation objects, including Proxy-wrapped variants. Script context options retain the distinct `getContextOptions` sequence: initial name/origin/mode reads, separate code-generation presence/validation/destructuring reads, and later mode validation using the initial snapshot for queue selection. Repeated getters can return different values; the regression checks cover that behavior and null/undefined destructuring failures.

Baseline diagnostics demonstrate the differences in the native executable at `ec4c453823b6d737a358d1c5e8899ff3f7bd20eb`: early/duplicate microtask reads, hidden getter exceptions, observable Proxy `has` operations and eight accepted invalid array/function inputs. Post-fix diagnostic JSON agrees exactly with Node v26.10.0.

Source checkpoint `29bc2badd` passed the 56-step native build, 44 unchanged files from pinned Bun commit `4982b91e3702094330f3be3883354c52b8c01323`, and six focused commands. The original reports contain 14 passing registered test cases and 39 passing file-process checks, with no failed files, skips, TODOs, filtering, retries or crashes. The focused commands cover Node/Home VM memory, option snapshots and GC during getters, Home context collection and inspector console behavior, and both diagnostic comparisons. Pickier on the changed facade/test and the whitespace check passed.

The added script checkpoint initially kept a third context in the memory fixture's async scope; both Node and Home correctly reported three contexts instead of the intended two. The option checks were moved into a separate function so the memory measurement controls remain isolated. The failed scope experiment and the preceding successful focused run are retained; the expected participant count was not changed.

`manifest.json` records source and executable hashes, all 44 original Git-object identities, every report and 464 deterministic gzip artifact identities. All launch events used the recorded native Home executable. Tests used the 3,840 MB guard, compilation used 8,192 MB, and shared-volume admission thresholds and deadlines were preserved.

This selected evidence does not establish full Bun suite or other-platform acceptance, an independently built runtime, or completion of the broader module/export/callback lifetime requirements.
