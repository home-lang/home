# Inference from `keyof` arguments (#998)

Literal keys supply a low-priority object-shape candidate for the type
parameter beneath `keyof`. Separate arguments contribute separate candidate
shapes. A normal value argument takes priority over the key-derived shape.
The oracle audit compares the complete diagnostic stream with TypeScript 5.7.3.

`tsconfig-grouping.json` checks how keys from array elements, fixed tuple
positions, rest arguments, spread tuples, and conditional expressions combine.
It also verifies that a constraint, explicit type argument, or ordinary value
argument still rejects a missing key.
