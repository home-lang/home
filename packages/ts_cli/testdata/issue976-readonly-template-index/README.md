# Readonly template index oracle (#976)

`readonly [key: \`data-${string}\`]: string` forbids writing the keys its
pattern matches while leaving every other key of the same string domain
writable. Home's pattern-signature metadata kept the key type, the value type
and the declaration node but dropped the readonly flag, and the
string/number/symbol readonly domains cannot express a key subset — so all
three forbidden writes were accepted.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`template.ts` pins six TS2542 against four writable controls. The readonly
writes cover a string literal matching the pattern, a member access, and an
index whose *type* is the template rather than a literal. The writable
controls cover a plain member, a plain string literal, a `string`-typed key
and a numeric key — none of which the pattern matches, so the mutable string
index still governs them. The remaining rows cover the surfaces the signature
has to survive: a type alias, an interface that inherits it, a declared
member that takes precedence over a matching pattern, and reads, which are
always allowed.

The same metadata is what the driver's `checked transfer preserves real
declarations and distinct callable identities` test asserts through
`readonly_index_types`; that test was red before this change.

[Issue #976](https://github.com/home-lang/home/issues/976) tracks this work.
