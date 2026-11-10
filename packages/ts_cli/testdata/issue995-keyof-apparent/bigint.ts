declare const big: bigint;

// A `bigint` reads `BigInt`'s surface. It borrowed `Number`'s, so the
// `Number`-only methods were accepted and `valueOf` returned a `number`.
const fixed = big.toFixed(2);
const precision = big.toPrecision(3);
const value: bigint = big.valueOf();
const text: string = big.toString(16);
const locale: string = big.toLocaleString();
const tag: "BigInt" = big[Symbol.toStringTag];

void [fixed, precision, value, text, locale, tag];
