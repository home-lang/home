# Inspector merged-main investigation — 2026-10-13

Concurrent TypeScript changes were merged without conflict and the combined executable rebuilt in 56/56 steps. The focused context/async/profiler/realm controls passed. The broader native run retained 26 passing groups and one fetch-resource-timing failure: stream cancellation produced no timing entry within the original deadline. A logging-only diagnostic later passed; it does not replace or erase the failed gate. ABI tests (14/453 assertions) and report-validator tests (32) passed separately.

Twenty unchanged upstream files retain 53 passed cases, one failed expectation and 17 process checks. All 64 report outcomes match prior expected counts/errors/exits, including 12 negatives. A returned-function-scope collection probe still retains the Home context without any inspector, while Node collects it. No collection pass credit or merged-main acceptance claim.

The source is preserved on the integration branch while the fetch timing failure is investigated. The [manifest](./manifest.json) records exact source/executable identities and raw artifacts. Full parity remains [#66](https://github.com/home-lang/home/issues/66); inspector lifetime/backend work remains [#888](https://github.com/home-lang/home/issues/888).
