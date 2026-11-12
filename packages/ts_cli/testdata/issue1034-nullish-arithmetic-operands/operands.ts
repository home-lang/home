declare const m: number | null;
declare const both: number | null | undefined;
declare const big: bigint | undefined;
declare const n0: null;
declare const o: { p?: number; q: number | null };
declare const maybe: { p?: number } | undefined;
declare const items: (number | undefined)[];
declare function next(): number | undefined;
enum E { A, B }
declare const e: E | undefined;

// The issue's rows: a possibly nullish operand is named.
function issueRows(n: number | undefined) {
  const a = m - 1;
  const b = n - 1;
  const c = n * 2;
}

// Every arithmetic operator, on either side.
function operators(n: number | undefined) {
  const a = 1 - n;
  const b = both / 2;
  const c = n % 2;
  const d = n ** 2;
  const e1 = n & 1;
  const e2 = 1 | n;
  const e3 = n ^ 1;
  const e4 = n << 1;
  const e5 = n >> 1;
  const e6 = 1 >>> n;
  const e7 = n * n;
}

// An entity name is named; anything else is "Object is possibly ...".
class Counter {
  count?: number;
  step() { return this.count - 1; }
}
function shapes(n: number | undefined) {
  const a = o.p - 1;
  const b = o.q * 2;
  const c = maybe?.p - 1;
  const d = next() - 1;
  const g = items[0] - 1;
  const h = (n) - 1;
  const i = 2 - (o.q);
  const j = n0 - 1;
  const k = e - 1;
  const l = null - 1;
  const q = undefined * 2;
  const r = (null) - 1;
}

// The operand continues without `null` and `undefined`.
function results(n: number | undefined) {
  const a: string = big - 1n;
  const b: string = big + 1n;
  const c: string = n - 1;
  const d: string = o.q + 1;
}

// Unary operators and compound assignments report the same way.
function unaryAndCompound(n: number | undefined) {
  const a = -n;
  const b = ~n;
  const c = +n;
  o.p -= 1;
  o.q *= 2;
  o.p++;
  items[0] -= 1;
  let x = 1;
  x -= n;
  x |= n;
  x += n;
}

// A type parameter constrained to a nullable type is reported; an
// unconstrained one fails the arithmetic check instead.
function generic<T, N extends number | undefined>(t: T, n: N) {
  const a = n - 1;
  const b = t - 1;
}
export {};
