// Stacks datetime combines ternary bounds with two relational expressions.
// The '<' and later '>' must not become one speculative generic call/list.
let witnesses = 0;
for (const hours of [0, 1, 5, 12, 13, 23, 24]) {
  for (const hours12 of [false, true]) {
    const parts = { hours12 };
    const minimum = hours12 ? 1 : 0;
    const maximum = hours12 ? 12 : 23;
    const low = hours < minimum;
    const high = hours > maximum;
    const outside = hours < (parts.hours12 ? 1 : 0) || hours > (parts.hours12 ? 12 : 23);
    const both = hours < (parts.hours12 ? 1 : 0) && hours > (parts.hours12 ? 12 : 23);
    const first = hours < (parts.hours12 ? 1 : 0) ?? hours > (parts.hours12 ? 12 : 23);
    if (outside !== (low || high) || both !== (low && high) || first !== low) {
      throw new Error(`Relational bounds changed for ${hours}:${hours12}`);
    }
    witnesses += 3;
  }
}
if (witnesses !== 42) {
  throw new Error(`Expected 42 executed comparison witnesses, got ${witnesses}`);
}
