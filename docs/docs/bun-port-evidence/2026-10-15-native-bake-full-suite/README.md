# Native Bake full-suite checkpoint

Source: `ccecdcf9b0ddceb40473a0054d9cd462fb3cfb75`. Bun corpus: `4982b91e3702094330f3be3883354c52b8c01323`. Platform: Darwin arm64/APFS. Parent: [#66](https://github.com/home-lang/home/issues/66); tranche: [#902](https://github.com/home-lang/home/issues/902).

The runner uses genuine Home-generated base and React lockfiles migrated from the maintained npm locks. Native frozen installs leave both locks byte-identical, and the negative manifest-mismatch probe fails without changing its lock. npm materializes the fixed dependency graphs; Home executes the tests and native children. Node remains the unchanged browser simulator.

A full suite now retains its source inventory, executable identity, launch context, complete streams, JUnit, exact case metadata and terminal counters. Its outer capture budget covers the 24 distinct sources without changing any original per-test deadline. The independent validator remains required for successful runner exit.

The first complete run produced 175 passes, two actual failures and two upstream TODOs. Its valid evidence is preserved as a failed checkpoint. Native dispatch was moving a spawned deinitialization fixture out of its requested working directory. The production source provider also omitted the lookup of stored source-map JSON. Both implementations are repaired. The broader coordinator controls additionally exposed path alias mismatches in `--changed` dependency graphs; canonical filesystem identities now match imported files to Git changes while caller paths remain available for execution and reporting.

The fresh complete run passes **177 cases with zero failures and zero skips across all 24 pinned source files**, with **two unchanged upstream TODOs**. Home and the independent validator both exit zero. The nested deinitialization fixture passes its nine cases. All final coordinator, development/HMR and production controls pass. The fresh 157-file regression passes 396 cases and 142 process checks with zero failures; 37 case skips and three file skips retain zero pass credit.

The regression controls cover spawned fixture working directories, original production source lines, changed dependencies through explicit symlink paths, and the existing suite/shard/bail/concurrency/coverage/isolation/parallel/configuration/root contracts. Controls are retained alongside every failed intermediate run. The manifest distinguishes current source hashes and executable identity from earlier evidence.

The two upstream TODOs receive zero pass credit. Linux, Windows and optimized native runtime execution remain open. This tranche does not establish that the entire Bun feature set or test suite passes.

Each `raw/*.gz` file is deterministic gzip with a manifest hash of its uncompressed bytes. Committed Git blobs are independently decompressed and hash-checked after publication preparation.
