# Inference from `keyof` arguments (#998)

Literal keys supply a low-priority object-shape candidate for the type
parameter beneath `keyof`. Separate arguments contribute separate candidate
shapes. A normal value argument takes priority over the key-derived shape.
The oracle audit compares the complete diagnostic stream with TypeScript 5.7.3.

`tsconfig-grouping.json` checks how keys from array elements, fixed tuple
positions, rest arguments, spread tuples, and conditional expressions combine.
It also verifies that a constraint, explicit type argument, or ordinary value
argument still rejects a missing key.

`tsconfig-keys.json` compares numeric and unique-symbol key arguments with
both native compilers. They infer an empty object candidate, while a mixed
string/numeric union keeps only the string property. The fixture also checks
the resulting argument and indexed-access diagnostics.

`tsconfig-dependent.json` checks parameters constrained by `keyof U`, concrete
`keyof` constraints, and a plain `string` constraint. The first two infer
different object shapes; the plain string constraint leaves the result unknown.

`tsconfig-constraint-alias.json` checks `keyof` aliases, a literal union
constraint, and the single-key boundary. A single literal constraint leaves
the inferred result unknown; a union of literal keys contributes members.

`tsconfig-key-domains.json` checks broad string, number, and symbol members in
source key constraints. Members that cannot form a LiteralKeyof candidate do
not erase candidates contributed by string or string-literal members.

`tsconfig-composite-constraints.json` checks base constraints of `keyof` over
unions and intersections of generic and concrete operands. It compares the
broad and finite domains, including a concrete single-key boundary.
