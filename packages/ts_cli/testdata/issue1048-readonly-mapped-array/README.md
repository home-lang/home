#1048: homomorphic readonly arrays

`Readonly<number[]>` and a user-defined homomorphic readonly mapping over
`number[]` must behave like `readonly number[]`: no mutators or index writes,
no assignment to mutable arrays, and valid assignment to readonly arrays.
The tuple rows preserve readonly position and assignment behavior.

The exact diagnostic stream is checked against TypeScript 5.7.3.
