# Generic `keyof` writes (#998)

An unconstrained type parameter, `extends any`, and `extends unknown` do not
guarantee a literal key. A named object constraint guarantees only its declared
keys. A type parameter constrained to `never` follows TypeScript's property-key
domain rule. The oracle audit compares the complete diagnostic stream and exit
status with TypeScript 5.7.3.

`tsconfig-chain.json` checks a 21-parameter acyclic constraint chain. The
guaranteed key passes, and the invalid key produces the same nested relation
diagnostic as both native TypeScript compilers.

`tsconfig-cycle.json` checks that a circular pair reports both declaration
errors and the invalid write without recursive key collection or a crash.

`tsconfig-program.json` uses the installed TypeScript library to compare a
direct generic `keyof` write, the same invalid key nested in a tuple element,
numeric key widening, later writes to an existing tuple binding, and two
inferred literal keys. The public Program test
embeds the shared source from `packages/ts_program/src/testdata` and
checks each diagnostic's byte position, message, and nested relation reason.
