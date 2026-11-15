declare const items: number[];
declare const c: boolean;

// The issue's rows: a parameter narrows by an assignment, plain or compound.
function param(p: 0 | 1) {
  p += 1;
  const r: "q" = p;
}
function plainParam(p: number | string) {
  p = 1;
  const r: "q" = p;
}

// Optional, defaulted, rest and generic parameters, string concatenation,
// and a write nested in an expression.
function optionalParam(p?: number) {
  p = 1;
  const r: "q" = p;
}
function defaultParam(p: number | string = "s") {
  p = 1;
  const r: "q" = p;
}
function rest(...xs: number[]) {
  xs = [];
  const r: "q" = xs;
}
function generic<T>(p: T | undefined, v: T) {
  p = v;
  const r: "q" = p;
}
function concat(s: "a" | "b") {
  s += "c";
  const r: "q" = s;
}
function nestedParam(p: number | string) {
  const t = (p = 1) + 1;
  const r: "q" = p;
}

// Destructured parameters, arrows and methods.
function destructured({ d }: { d: number | string }) {
  d = 1;
  const r: "q" = d;
}
function arrayPattern([e]: [number | string]) {
  e = 1;
  const r: "q" = e;
}
const arrow = (p: number | string) => { p = 1; const r: "q" = p; };
class K {
  m(p: number | string) { p = 1; const r: "q" = p; }
}

// Joins: a loop or a branch may not assign.
function loopParam(p: number | string) {
  for (const i of items) { p = i; }
  const r: "q" = p;
}
function branchParam(p: number | string) {
  if (c) p = 1;
  const r: "q" = p;
}
function narrowedThenAssigned(p: number | string) {
  if (typeof p === "string") { p = p.length; }
  const r: "q" = p;
}

// A closure's write narrows its own reads only; a shadowing local is its
// own variable.
function closureWrite(p: number | string) {
  const g = () => { p = 1; };
  const r: "q" = p;
}
function closureLocal(p: number | string) {
  const g = () => { p = 1; const r: "q" = p; };
}
function shadowed(p: number | string) {
  { let p = "x"; p = "y"; }
  const r: "q" = p;
}
export {};
