// The issue's rows: a loop binding read in its own initializer or
// `for...in` source is in its temporal dead zone.
function loops(o: object) {
  for (let a = a; a; ) { }
  for (let k in k) { }
  for (let v of v) { }
  for (const c = c; ; ) { break; }
  for (const h in h) { }
  for (const [g] of g) { }
  for (var m in m) { }
  for (var n = n; ; ) { break; }
  return o;
}

// The same reads in a plain declaration, in a function and at the top
// level. A `var` is not block-scoped, so it reports only the circularity.
function declarations() {
  let x = x + 1;
  const y = y;
  var w = w;
  let t = typeof t;
  let arr = [arr];
  const cast = (cast as any) + 1;
}
let top = top;

// An inner binding shadows an outer one from the start of its scope.
function shadowed() {
  let s = 1;
  {
    let s = s + 1;
  }
  return s;
}

// An annotated binding reads as declared. Without `undefined` in its type
// it is also used before being assigned.
function annotated() {
  let a: number = a;
  let u: number | undefined = u;
  var b: number = b;
}

// A function body runs later; a class body inside the initializer does not.
function deferred() {
  let h = function () { return h; };
  let C = class { static s = C; i = C; };
}
export {};
