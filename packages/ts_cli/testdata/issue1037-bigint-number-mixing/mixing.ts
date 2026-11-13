declare const bb: bigint;
declare const nn: number;
declare const an: any;
declare const nb: number | bigint;
declare const lit: 1n | 2n;
declare const nev: never;
declare const ob: bigint | undefined;
declare const pb: Promise<bigint>;
declare const pn: Promise<number>;
enum E { A, B }

// The issue's rows: `>>>` on bigints, and mixing `bigint` with `number`.
const issue1 = bb >>> 1n;
const issue2 = bb - 1;
const issue3 = 1 * bb;

// Every other arithmetic, bitwise and shift operator.
const op1 = bb / nn;
const op2 = nn % bb;
const op3 = bb ** 2;
const op4 = bb & 1;
const op5 = 1 | bb;
const op6 = bb ^ nn;
const op7 = bb << 1;
const op8 = bb >> nn;
const op9 = 1n >>> 2n;
const op10 = lit >>> 1n;

// A mix shows base types; a union that may be either is a mix too.
const base1 = nb - 1n;
const base2 = nb * nb;
const base3 = E.A - 1n;
const base4 = lit - 1;
const base5 = "a" - 1n;
const base6 = true * 1n;
const base7 = ob - 1;

// `any` and `never` are bigint-like; a promise suggests `await`.
const like1 = an - 1n;
const like2 = nev - 1n;
const like3 = pb - 1n;
const like4 = pb - pn;

// The result: `bigint` for bigints, the error type for a mix.
const r1: string = 1n & 2n;
const r2: string = bb >> 1n;
const r3: string = an * 1n;
const r4: string = nb - nb;
const r5: string = lit * lit;

// `+` shows the operands' own types.
const plus1 = bb + 1;
const plus2 = 1 + bb;
const plus3 = nb + nb;
const plus4 = bb + "s";
const plus5: string = bb + 1n;
function generic<T extends bigint, U extends number>(t: T, u: U) {
  const p = t + u;
}

// Compound assignments.
let b: bigint = 1n;
b -= 1;
b >>>= 1n;
b **= 2;
b += 1;
let n = 1;
n *= 2n;
n |= bb;
n += 1n;
export {};
