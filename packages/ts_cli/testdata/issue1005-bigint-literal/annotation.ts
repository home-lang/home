declare const obj: { q: 1 };
declare const big: bigint;
declare const one: 1n;

// A bigint literal type rejects every other value.
const a: 1n = obj;
const b: 1n = "s";
const c: 1n = 2n;
const d: 1n = 1;
const f: 1n = big;
const g: 2n | 1n = 3n;
const i: -1n = 1n;
const l: 2n = one;
const m: number = one;

// It accepts itself, a declared value of its type, and its supertype takes
// it.
const e: 1n = 1n;
const h: 2n | 1n = 1n;
const j: -1n = -1n;
const k: bigint = one;

// The value is what counts, not how it is written: `0x10n` is `16n`, and
// `-0n` is `0n`.
const hex: 0x10n = 16n;
const hexBad: 0x10n = obj;
const sep: 1_000n = 1000n;
const sepBad: 1_000n = 0x10n;
const zero: -0n = 0n;
const zeroBad: -0n = obj;
const radix: 0o7n | 0b11n = 4n;

// At a parameter, in an object and in an array.
function take(p: 1n) { void p; }
take(2n);
take(-1n);
take(1n);
take(obj);
function wide(p: number) { void p; }
wide(2n);
const y: { v: 1n } = { v: 2n };
const z: 1n[] = [1n, 2n];
void [a, b, c, d, e, f, g, h, i, j, k, l, m, hex, hexBad, sep, sepBad, zero, zeroBad, radix, y, z];
export {};
