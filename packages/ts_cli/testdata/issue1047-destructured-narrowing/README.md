# Destructured binding narrowing oracle (#1047)

`typeof` guards narrow identifiers introduced by object and array binding
patterns in parameters and local declarations. Reassigning a local binding
changes its flow type, and an inner binding with the same name shadows the
outer binding without changing its type after the inner block.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. Both should exit successfully
without diagnostics. The `test-tsc-streams` audit compares stdout, stderr,
and exit status exactly.

[Issue #1047](https://github.com/home-lang/home/issues/1047) tracks this work.
