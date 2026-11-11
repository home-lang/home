declare const one: 1n;
declare const big: bigint;
declare const nb: number | bigint;
declare const u: 1n | 2n | 3n;

// A `const` keeps a bigint literal and a `let` widens it.
const c = 1n;
const c2: 2n = c;
let l = 1n;
const l2: 2n = l;
const neg = -5n;
const neg2: 5n = neg;

// `as const` keeps it in an object and a tuple.
const o = { k: 1n } as const;
const o2: { k: 2n } = o;
const arr = [1n, 2n] as const;
const arr2: readonly [2n, 2n] = arr;

// Comparison and narrowing.
if (one === 2n) {}
if (u === 2n) { const n: 3n = u; void n; }
if (u !== 2n) { const n: 2n = u; void n; }
switch (u) { case 1n: { const s: 2n = u; void s; break; } }
if (big === 1n) { const b: 2n = big; void b; }

// `-` and `~` keep a bigint a bigint; with a number possible, both.
const x1: string = -big;
const x2: string = ~big;
const x3: string = -nb;
const x5: string = ~nb;
const sum: 3n = one + one;
void [c2, l2, neg2, o2, arr2, x1, x2, x3, x5, sum];
export {};
