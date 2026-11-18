# Union alias identity (#1003)

Two aliases with the same union members keep separate declaration identities.
An unrelated union with those members remains unnamed; a reference through a
second alias keeps the original union name. The fixture checks direct variable
annotations, array elements, and nested object property annotations.
It also assigns between the two named unions and the unnamed union in both
directions; those assignments must remain valid.

`tsconfig-imports.json` checks the same distinction after aliases cross a
module boundary. The imported names must remain `U` and `V`; a separately
written union with identical members remains unnamed. It also checks that
chains through `W = U` and `X = V` keep the defining union names, while
assignments between those imported aliases and the bare union remain valid.

TypeScript 5.7.3 and native TypeScript 7.0.2 produce identical diagnostic text
for every row. The oracle audit compares Home's full stream and exit status
against 5.7.3. See [issue #1003](https://github.com/home-lang/home/issues/1003).
