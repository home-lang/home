// A number literal type prints as JavaScript's Number.prototype.toString
// writes the number.

// Exponent form from 1e21 up and below 1e-6, with a `+` on a positive exponent.
const a: 1 = 1e21;
const b: 1e21 = 2;
const c = 1e21;
const c2: 1 = c;
const d: 1 = 1.5e-7;
const e = -1e-7;
const e2: 1 = e;
const m: 1 = 1.7976931348623157e308;
const s: 1 = 5e-324;

// Plain digits in between, the shortest that round-trip.
const f: 1 = 123456789012345680000;
const g: 1 = 1152921504606846976;
const h: 1 = 0.000001;
const p: 1 = 0.1;

// The same text inside a template literal and in an `as const` tuple.
const tv = `a${1e21}` as const;
const tv2: "b" = tv;
const tz = `${-0}` as const;
const tz2: "b" = tz;
const tup = [1e21, 2e-7] as const;
const tup2: readonly [1, 2] = tup;
void [a, b, c2, d, e2, m, s, f, g, h, p, tv2, tz2, tup2];
export {};
