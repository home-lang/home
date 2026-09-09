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
