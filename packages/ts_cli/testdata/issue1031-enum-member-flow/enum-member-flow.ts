enum E { A, B }
function f() {
  let e: E = E.A;
  const r1: E.B = e;
  let g = E.A;
  const r2: E.B = g;
}
export {};
