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

`tsconfig-direct-composite.json` checks the distinct Index-vs-Index inference
path for direct `keyof (U & V)` arguments and apparent-domain inference for
direct `keyof (U | V)` arguments, including raw nested call diagnostics.

`tsconfig-deep-composite.json` checks several Index candidates, including a
candidate constrained by an intersection of another candidate and an object.
It also compares the full diagnostic chains through multiple type-parameter
constraints and the symbolic `keyof` subtype relation at the call site.

`tsconfig-long-composite.json` follows a 20-link acyclic parameter constraint
chain. It checks that the final concrete base still supplies `present`, while
the independent `other` key does not become a member of the inferred result.

`tsconfig-cycle-composite.json` checks a two-parameter circular constraint.
The checker must terminate and preserve the exact TS2313, TS2345, TS2322, and
TS2339 diagnostic stream, including the widened property-key explanation.

`tsconfig-cycle-three.json` and `tsconfig-cycle-four.json` extend that check to
three- and four-parameter cycles. Both include a literal write to `keyof A` so
the circular constraint cannot accidentally grant a writable key.
