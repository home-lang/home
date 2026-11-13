declare const items: number[];
enum E { A, B }

// The issue's row: after `+=`, `x` reads as `number`, not as `0 | 1`.
function issue() {
  let x: 0 | 1 = 0;
  x += 1;
  const r: "q" = x;
}

// An update, string concatenation, a mixed union, an enum and a single
// literal widen the same way.
function update() {
  let x: 0 | 1 = 0;
  x++;
  const r: "q" = x;
}
function strings() {
  let s: "a" | "b" = "a";
  s += "c";
  const r: "q" = s;
}
function mixed() {
  let m: 0 | 1 | "a" = "a";
  m += 1;
  const r: "q" = m;
}
function enums() {
  let e: E.A | E.B = E.A;
  e += 1;
  const r: "q" = e;
}
function single() {
  let z: 0 = 0;
  z += 1;
  const r: "q" = z;
}

// Joins carry the widened type out of a loop and a branch, and into the
// next iteration.
function inLoop() {
  let k: 0 | 1 = 0;
  for (const i of items) { k += i; }
  const r: "q" = k;
}
function loopBefore() {
  let k: 0 | 1 = 0;
  for (const i of items) {
    const r: "q" = k;
    k += i;
  }
}
function branch(c: boolean) {
  let b: 0 | 1 = 0;
  if (c) b += 1;
  const r: "q" = b;
}

// A later plain assignment narrows again, and a variable of the same name
// elsewhere keeps its own type.
function reassigned() {
  let x: 0 | 1 = 0;
  x += 1;
  x = 1;
  const r: "q" = x;
}
function otherFunction() {
  let x: 0 | 1 = 1;
  const r: "q" = x;
}
export {};
