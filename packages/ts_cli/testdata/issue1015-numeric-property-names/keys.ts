// `keyof` gives a numeric name its number literal type.
const k1: keyof { 1: string } = "1";
const k2: keyof { "1": string } = 1;
const k3: keyof { 1e21: string } = "1e+21";
const k4: keyof { 0x10: string } = 17;
interface I { 1: string; a: number }
type Ex = Exclude<keyof I, "a">;
const ex: Ex = "1";
function f<K extends keyof I>(k: K): I[K] { return null!; }
const fr: number = f(1);

// So a mapped type over number literal keys has those properties, and
// `K` is the number.
type M = { [P in 1 | 2]: P };
const m: M = { 1: 1, 2: 3 };
type Mk = { [P in keyof I]: boolean };
const mk: Mk = { 1: true, a: 1 };
type Pk = Pick<I, 1>;
const pk: Pk = { 1: 5 };
type Om = Omit<I, 1>;
const om: Om = { a: "x" };
type R = Record<1 | 2, string>;
const r: R = { 1: "a", 2: 2 };
void [k1, k2, k3, k4, ex, fr, m, mk, pk, om, r];
export {};
