// A missing member is named as its declaration writes it.
interface I { 1e21: string; 0x10: string; 1.50: string; 2: string }
const i: I = {};
interface J { 1e21: string }
const j: J = {};
interface S { 0b11: string }
const s: S = {};
interface Q { "a-b": string; 'c': string; d: string }
const q: Q = {};
type T = { 1e21: string };
const t: T = {};
class C { 1e21 = "x"; 0x10 = "y" }
const c: C = {};
const big = { 1e21: 1 };
const bigx: { 1e21: string } = big;

// A mapped member has no declaration: a numeric name is bare.
type M = { [P in 1 | 2]: string };
const m: M = { 1: "a" };
type M2 = { [P in "1" | "2"]: string };
const m2: M2 = { 1: "a" };
void [i, j, s, q, t, c, bigx, m, m2];
export {};
