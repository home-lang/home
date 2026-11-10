interface Zed { z: 1 }
interface Alpha { a: 1 }
declare const obj: { q: 1 };
declare const arrs: number[] | string[];
declare const za: Zed | Alpha;
declare const mixedSource: number | string | boolean;

// String literals sort by value, wherever the union is written.
const v1: "zeta" | "alpha" | "mid" = "x";
function f1(p: "zeta" | "alpha" | "mid") { void p; }
f1("x");
let v2: "zeta" | "alpha" | "mid" = "zeta";
v2 = "x";
const e1: ("zeta" | "alpha")[] = ["x"];
const p1: { p: "zeta" | "alpha" } = { p: "x" };

// Numeric literals sort by value; a primitive comes before a literal of
// another kind, and literal kinds go string, number, boolean.
const n1: 3 | 1 | 2 = 9;
const m1: number | string = obj;
const m2: boolean | number | string = obj;
const pl: number | "b" | "a" = true;
const lits: 2 | "two" | true = obj;

// Arrays sort by element type and named types by name, on the source side
// too, and the explanation names the first member in that order.
const ar: boolean[] = arrs;
const iz: string = za;

// `null` and `undefined` stay last.
const nu: string | undefined | null = 1;
const src: symbol = mixedSource;
void [v1, v2, e1, p1, n1, m1, m2, pl, lits, ar, iz, nu, src];
export {};
