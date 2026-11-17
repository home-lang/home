# Returned literal diagnostic source (#1004)

A literal return annotation relates the returned expression's literal value,
so an incompatible return reports `"bogus"`, `2`, or `false` rather than
their widened primitive types. The `keyof boolean` case checks a literal
target reached through type evaluation, and `broad` checks that a primitive
return target still uses the widened source.

The full stdout, stderr, and exit status are compared with both tsc 5.7.3
and native TypeScript 7.0.2; they agree for this fixture. Run from this
directory with `-p tsconfig.json --pretty false --noEmit`.

[Issue #1004](https://github.com/home-lang/home/issues/1004) tracks this work.
