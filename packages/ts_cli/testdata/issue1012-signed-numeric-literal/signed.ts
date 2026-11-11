// A sign applied directly to a numeric literal keeps the literal in a const.
const n = -5;
const n2: 5 = n;
const p = +5;
const p2: 6 = p;
const f = -1.5;
const f2: 1 = f;
const h = -0x10;
const h2: 1 = h;
const q = +0x10;
const q2: 1 = q;

// `-0` is the `0` literal.
const z = -0;
const z2: 1 = z;
const z3: 0 = z;

// And so does `as const`, alone, in an object and in a tuple.
const asc = -5 as const;
const asc2: 1 = asc;
const o = { k: -1 } as const;
const o2: { k: 1 } = o;
const arr = [-1, +2] as const;
const arr2: readonly [1, 2] = arr;

// A literal target and narrowing see the signed literal too.
const t1: 5 = +6;
declare const u: -1 | 1 | 2;
if (u === +2) { const x: 3 = u; void x; }
if (u === -1) { const y: 3 = u; void y; }

// A parenthesized or doubly signed operand, a `let` and a property without
// `as const` widen to `number`.
const par = -(5);
const par2: 1 = par;
const dbl = - -5;
const dbl2: 1 = dbl;
let l = -5;
const l2: 1 = l;
const w = { k: -1 };
const w2: { k: 1 } = w;
void [n2, p2, f2, h2, q2, z2, z3, asc2, o2, arr2, t1, par2, dbl2, l2, w2];
export {};
