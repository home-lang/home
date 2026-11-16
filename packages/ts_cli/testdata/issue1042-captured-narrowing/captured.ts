declare function take(x: "q"): void;

// The issue's rows: a closure created after the last assignment keeps the
// narrowing; one created before it reads the declared type.
function plain() {
  let x: string | number = 1;
  x = "a";
  const f = () => { const r: "q" = x; };
}
function literal() {
  let y: 0 | 1 = 0;
  y = 1;
  const f = () => { const r: "q" = y; };
}
function compound() {
  let z: 0 | 1 = 0;
  z += 1;
  const f = () => { const r: "q" = z; };
}
function before() {
  let w: string | number = 1;
  const f = () => { const r: "q" = w; };
  w = "a";
}
function initializerOnly() {
  let n: string | number = 1;
  const f = () => { const r: "q" = n; };
}

// Guards: a const, a parameter and a let with no later write.
function constGuard(c: string | number) {
  const k: string | number = c;
  if (typeof k === "string") { const f = () => { const r: "q" = k; }; }
}
function letGuard(c: string | number) {
  let k: string | number = c;
  if (typeof k === "string") { const f = () => { const r: "q" = k; }; }
}
function truthy(c: string | undefined) {
  if (c) { [1].map(() => c.length); }
}
function earlyReturn(p: string | undefined) {
  if (p === undefined) return;
  return () => take(p);
}
function nestedGuard(c: string | number | boolean) {
  if (typeof c !== "boolean") {
    const f = () => { if (typeof c === "string") take(c); else take(c); };
  }
}
function reassignedThenGuard(p: string | number) {
  p = "x";
  if (typeof p === "string") { const f = () => take(p); }
}

// Which functions carry the narrowing in.
function functionExpression() {
  let e: string | number = 1;
  e = "a";
  const f = function () { const r: "q" = e; };
}
function deeper(c: string | number) {
  if (typeof c === "string") { const f = () => () => () => take(c); }
}
function objectMethod(c: string | number) {
  if (typeof c === "string") { const o = { m() { take(c); }, get g() { return take(c); } }; }
}
function classExpression(c: string | number) {
  if (typeof c === "string") { const K = class { m() { take(c); } }; }
}
function classDeclaration(c: string | number) {
  if (typeof c === "string") { class K { m() { take(c); } } }
}
function classField(c: string | number) {
  if (typeof c === "string") { const K = class { f = () => take(c); }; }
}
function throughDeclaration(c: string | number) {
  if (typeof c === "string") { function g() { const f = () => take(c); } }
}
function iife(c: string | number) {
  if (typeof c === "string") { (() => { take(c); })(); }
}
function asyncIife(c: string | number) {
  if (typeof c === "string") { (async () => { take(c); })(); }
}

// Which bindings qualify.
function varDeclaration() {
  var v: string | number = 1;
  v = "a";
  const f = () => { const r: "q" = v; };
}
function catchVariable() {
  try { } catch (e) {
    if (typeof e === "string") { const f = () => take(e); }
  }
}
function loopConst(xs: (string | number)[]) {
  for (const x of xs) { if (typeof x === "string") { const f = () => take(x); } }
}
function shadowingParameter(c: string | number) {
  if (typeof c === "string") { const f = (c: number) => take(c); }
}

// Writes that keep the declared type.
function writeInClosure() {
  let m: string | number = 1;
  m = "a";
  const f = () => { const r: "q" = m; };
  const g = () => { m = 2; };
}
function writeInLoop(xs: number[], c: string | number) {
  for (const _ of xs) { if (typeof c === "string") { const f = () => take(c); } c = 1; }
}
function writeInBranch(b: boolean) {
  let i: string | number = 1;
  if (b) { i = "a"; const f = () => { const r: "q" = i; }; }
}

let topLet: string | number = "a";
topLet = 1;
const topArrow = () => take(topLet);
let exportedLater: string | number = "a";
const viaSpecifier = () => take(exportedLater);
export { exportedLater };
