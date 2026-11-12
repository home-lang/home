// Every path that reaches a read is joined, as in TypeScript's control flow
// graph: loops, `switch`, `&&` / `||` / `?:`, `try` and labeled blocks.
declare const items: number[];
declare const cond: boolean;
declare function maybe(): string | undefined;

// Loops join the entry with every write, at the head and at the exit.
function forOf() {
  let u: "a" | "b" | undefined = "a";
  for (const i of items) { if (i) u = "b"; }
  const r: "q" = u;
}
function whileLoop() {
  let u: "a" | "b" | undefined = "a";
  while (cond) { const head: "a" = u; u = undefined; }
  const r: "q" = u;
}
function doWhile() {
  let u: "a" | "b" | "c" = "a";
  do { u = "b"; } while (cond);
  const r: "q" = u;
}
function forever() {
  let u: "a" | "b" | "c" = "a";
  for (;;) { if (cond) { u = "b"; break; } u = "c"; }
  const r: "q" = u;
}
function labeledLoop() {
  let u: "a" | "b" | "c" = "a";
  outer: for (const i of items) { for (const j of items) { if (j) { u = "b"; break outer; } } }
  const r: "q" = u;
}
function nestedSwitch() {
  let u: "a" | "b" | "c" = "a";
  while (cond) { switch (cond) { case true: u = "b"; break; } u = "c"; }
  const r: "q" = u;
}
function assignedCondition() {
  let m: string | undefined = "a";
  while ((m = maybe()) !== undefined) { const inLoop: "q" = m; }
  const r: "q" = m;
}

// Boolean flags.
function found() {
  let found = false;
  for (const i of items) { if (i) { found = true; break; } }
  const r: "q" = found;
}
function first() {
  let first = true;
  for (const i of items) { const inLoop: "q" = first; first = false; }
  const after: "q" = first;
}
function done() {
  let done = false;
  while (!done) { done = cond; }
  const r: "q" = done;
}

// `switch` joins its clauses, falling through and breaking out.
function switched() {
  let u: "a" | "b" = "a";
  switch (cond) { case true: u = "b"; }
  const r: "q" = u;
}
function switchDefault(k: number) {
  let u: "a" | "b" | "c" = "a";
  switch (k) { case 1: u = "b"; break; default: u = "c"; }
  const r: "q" = u;
}
function fallthrough(k: "a" | "b" | "c") {
  let u: "x" | "y" | "z" = "x";
  switch (k) { case "a": u = "y"; case "b": u = "z"; break; }
  const r: "q" = u;
}
// A `switch` on the variable it assigns narrows each clause by its case.
function switchOnSelf(k: "a" | "b" | "c") {
  switch (k) { case "c": k = "a"; }
  const r: "q" = k;
}
function switchOnSelfDefault(k: "a" | "b" | "c") {
  switch (k) { case "a": break; default: k = "a"; }
  const r: "q" = k;
}

// Short-circuit and conditional expressions.
function logical() {
  let u: "a" | "b" = "a";
  cond && (u = "b");
  const r: "q" = u;
}
function orAssign() {
  let u: "a" | "b" | undefined = undefined;
  cond || (u = "b");
  const r: "q" = u;
}
function ternary() {
  let u: "a" | "b" | "c" = "a";
  cond ? (u = "b") : (u = "c");
  const r: "q" = u;
}

// `try` starts `catch` and `finally` from any point in the `try` block.
function tried() {
  let u: "a" | "b" | "c" = "a";
  try { u = "b"; } catch { const inCatch: "q" = u; u = "c"; }
  const r: "q" = u;
}
function finallyRead() {
  let u: "a" | "b" | "c" = "a";
  try { u = "b"; } finally { const inFinally: "q" = u; }
  const r: "q" = u;
}

// A labeled block ends with each `break` to its label.
function labeledBlock() {
  let u: "a" | "b" | "c" = "a";
  lbl: { if (cond) { u = "b"; break lbl; } u = "c"; }
  const r: "q" = u;
}

// A branch write is reduced against the declared type.
function branches() {
  let u: string | undefined = undefined;
  if (cond) { u = "x"; } else { u = "y"; }
  const r: number = u;
}

// A write in a callback is not part of the enclosing flow.
function callback(run: (f: () => void) => void) {
  let d = false;
  run(() => { d = true; });
  const r: "q" = d;
}

// The same joins hold at the top level of a file.
let topFound = false;
for (const i of items) { if (i) { topFound = true; break; } }
const topR: "q" = topFound;
let topU: "a" | "b" = "a";
while (cond) { topU = "b"; }
const topR2: "q" = topU;
export {};
