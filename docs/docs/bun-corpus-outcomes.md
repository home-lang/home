# Native corpus outcome records

The native corpus CLI creates a new results directory for every invocation and prints its absolute path. The default location is `zig-out/bun-corpus-results/<unique-id>`. Set `HOME_BUN_CORPUS_REPORT_DIR` to a new directory to choose a durable destination; its parent must already exist. Existing destinations are rejected before any fixture executes.

Every run writes `events.jsonl`. All selected paths are flushed before the first launch. A `started` event means a launch attempt; it records the executable and source SHA256, exact arguments, working directory, selected environment settings, and actual deadline. A `completed` event records process termination, timeout, source integrity, raw test counters, full captured stdout/stderr paths and hashes, and retained JUnit identity when requested. The final `finished` event records totals and whether every selection completed. An interrupted run retains its unfinished selection; absence of completion is never success.

Ordinary test-runner corpus files receive native JUnit reporting alongside their existing launch options. The report stays in the results directory when per-file temporary storage is removed. Node and script files retain their upstream launch contract. A successful script or a comment-only file does not manufacture registered passing cases. Skipped tests and TODO tests have separate counters; neither counts as implemented passing coverage. Expected-failure fixtures retain their original failing case evidence and receive only the existing verified process-check classification.

Validate a retained run with:

```sh
python3 scripts/summarize-bun-corpus.py /absolute/path/to/results
```

The validator emits JSON containing individual JUnit cases, separate outcome counts, unstarted and incomplete selections, and evidence errors. It checks raw capture and JUnit hashes, parses XML, and compares registered case outcomes with the process counters. It exits nonzero for failed or incomplete execution, malformed case reports, changed source, mismatched evidence, or unsupported files. Retained report presence alone does not mean the XML has been validated; the journal labels it `retained` until the validator inspects it.

The journal preserves captures after a child terminates. A runner killed during a child execution has a durable selection and launch attempt, but no claimed completed capture. Keep these directories with the associated source revision and build evidence when comparing corpus runs. The launch environment record includes only explicit runtime and CI settings, not arbitrary inherited credentials.

This mechanism is execution evidence, not a full Bun parity claim. Track the complete port in [#66](https://github.com/home-lang/home/issues/66) and the reporting contract in [#722](https://github.com/home-lang/home/issues/722).
