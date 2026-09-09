# Native corpus outcome records

The native corpus CLI creates a new results directory for every invocation and prints its absolute path. The default location is `zig-out/bun-corpus-results/<unique-id>`. Set `HOME_BUN_CORPUS_REPORT_DIR` to a new directory to choose a durable destination; its parent must already exist. Existing destinations are rejected before any fixture executes.

Every run writes `events.jsonl`. All selected paths are flushed before the first launch. A `started` event means a launch attempt; it records the executable and source SHA256, exact arguments, working directory, selected environment settings, and actual deadline. A `completed` event records process termination, timeout, source integrity, raw test counters, full captured stdout/stderr paths and hashes, and retained JUnit identity when requested. Schema 2 also records `output_complete`: whether both captured streams reached EOF. The validator retains compatibility with schema 1, where capture completeness remains unknown. The final `finished` event records totals and whether every selection completed. An interrupted run retains its unfinished selection; absence of completion is never success.

Ordinary test-runner corpus files receive native JUnit reporting alongside their existing launch options. The report stays in the results directory when per-file temporary storage is removed. Node and script files retain their upstream launch contract. A successful script or a comment-only file does not manufacture registered passing cases. Skipped tests and TODO tests have separate counters; neither counts as implemented passing coverage. Expected-failure fixtures retain their original failing case evidence and receive only the existing verified process-check classification.

Validate a retained run with:

```sh
python3 scripts/summarize-bun-corpus.py /absolute/path/to/results
```

The validator emits JSON containing individual JUnit cases, separate outcome counts, unstarted and incomplete selections, and evidence errors. It checks raw capture and JUnit hashes, parses XML, and compares registered case outcomes with the process counters. Schema 2 captures that do not reach verified EOF fail validation. It exits nonzero for failed or incomplete execution, malformed case reports, changed source, mismatched evidence, or unsupported files. Retained report presence alone does not mean the XML has been validated; the journal labels it `retained` until the validator inspects it.

The selected absolute process deadline continues after both output pipes reach EOF; closing output does not grant a still-running child an unlimited lifetime. Exit observation keeps the child unreaped until the owning capture performs final cleanup.

An explicit CI selection policy adds a `selection` event before file selection. It retains the complete primary inventory, excluded files and expectation metadata, additional Home coverage, and any partial execution range. The validator checks the inventory partition and exact selected execution paths. Exclusions remain separate from registered skipped or passing cases. Prepared vendor runs also retain their full discovery inventory, original skip patterns, pinned checkout revision and the explicit `setup_performed: false` boundary. Vendor execution uses the same durable case and capture validation. See [native selection and vendor execution](./bun-corpus-selection.md) for the API and its remaining orchestration work.

The journal preserves captures after a child terminates. A runner killed during a child execution has a durable selection and launch attempt, but no claimed completed capture. Keep these directories with the associated source revision and build evidence when comparing corpus runs. The launch environment record includes only explicit runtime and CI settings, not arbitrary inherited credentials.

This mechanism is execution evidence, not a full Bun parity claim. Track the complete port in [#66](https://github.com/home-lang/home/issues/66) and the reporting contract in [#722](https://github.com/home-lang/home/issues/722).

## Native installation outcomes

`home test --bun-corpus-setup` runs the original root and test package installations through Home. Its schema-2 run header declares `purpose: "setup"`; older journals without a purpose retain their corpus meaning. A `setup_plan` records the pinned revision, manifest hash, all protected input hashes, actual host and expected platform, and both original install steps before either launch. Each install has the original 180,000 ms deadline, a fresh temporary/cache directory, native command aliases and complete output capture. The setup launcher also implements the original 60,000 ms build profile for subsequent vendor preparation.

The runner attempts both installs even if the first fails. It verifies every protected input before installation and after each step. A changed input is recorded as `setup_input_changed` and cannot produce successful setup. Installation output never registers test cases: all four case counters remain zero, `observed` is false, JUnit is not requested and successful process-check credit is zero. Setup success and failure have their own summary counters. The validator checks the two original steps, exact commands and deadlines, package hashes, working directories, capture integrity and separate outcome counts. An original installation failure yields unsuccessful validation even when the retained failure evidence is internally consistent.

This command supplies native root/test installation and its durable outcomes. Integration into the default full CI coordinator remains tracked in #724; the missing optional legacy DuckDB dependency remains unresolved in #725.

## Service and vendor preparation outcomes

A schema-2 `purpose: "service"` journal records the original remap launch contract, dependency hashes, readiness, and a `service_completed` event. Ready port, startup timeout, invalid readiness, unexpected exit, owner-requested shutdown, termination and capture completeness remain separate fields. An intentional service termination is not an expected test failure. Successful service completion requires readiness, owner-requested shutdown, unchanged source and complete output capture; all case and process-check counters stay zero.

A `purpose: "vendor_setup"` journal selects all clone/fetch/checkout/revision/install/build operations before launching any. It retains separate Git and Home executable identities, exact arguments and deadlines, verified revision outputs, and package hashes. Switching executable identity remains forbidden for ordinary corpus and setup journals. The validator checks each vendor command against the recorded manifest and checks HEAD/tag output against the checkout record. Preparation has its own success/failure counters and never registers test cases. Full CI orchestration is not implied by successful explicit preparation.
