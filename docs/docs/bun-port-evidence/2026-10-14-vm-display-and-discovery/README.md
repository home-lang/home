# VM displayErrors and complete pinned VM discovery

This checkpoint implements #892 and contributes to #66. Native script execution now decorates error stacks only when displayErrors is enabled. The default and true behavior is preserved. False leaves the original thrown error untouched and does not invoke a user-defined stack getter. Nested VM boundaries retain decoration already applied by an enabled inner boundary; an enabled outer boundary can decorate an undecorated error once.

The Node v26.10.0 oracle and Home agree on all 14 method, nesting and getter-suppression rows. Source `57f6260bf` passed the 56-step native build, six focused commands, Pickier and the whitespace check. Node/Home memory and option regressions, Home context collection, inspector console behavior and both display diagnostic commands passed.

Discovery and execution cover every pinned parallel test-vm file (97) and every top-level Bun-specific node/vm test file (7), for 104 unique unchanged files from Bun commit `4982b91e3702094330f3be3883354c52b8c01323`. Every source was compared to its pinned Git object. All final file launches used the recorded native Home executable.

The 99-file combined batch had 24 passing registered test cases and 92 passing process checks, without failed files, skips, TODOs, filtering, retries or crashes. This includes the context/property, module, watchdog/microtask timeout, memory, SIGINT, caught-parse-error and low-stack tests. The four additional happy-dom/script-leak/module-leak/concurrent-GC-linking files passed unchanged. The main vm.test.ts file had 206 passing cases, no failures, two upstream skips and 66 upstream TODOs. The complete 104-file aggregate is 234 passing registered cases and 92 passing process checks, with 2 skips and 66 TODOs. Skips and TODOs receive no completed-feature credit.

The manifest separates baseline discovery batches from final executable validation. It records source/executable hashes, all original identities, all reports and 790 deterministic gzip artifact identities. The earlier default/false decoration and stack-getter differences remain in the raw baseline comparisons. The final lifetime batch peaked at 367 MB under the unchanged 3,840 MB test guard; build guard and volume admission thresholds remained unchanged.

This file scope is not full Bun suite or feature acceptance. The 66 TODOs and two skips, broader evaluated-context/module/export/callback lifetime acceptance in #885, remaining #891 integration, other platforms and independent runtime builds remain outstanding.
