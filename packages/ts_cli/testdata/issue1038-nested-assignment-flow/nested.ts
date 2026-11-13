declare const a: number;
declare const c: boolean;
declare const r: number[];
declare const o: { f?: (n: number) => void } | undefined;
declare function take(n: number): void;

// The issue's rows: a write nested in an expression narrows the variable.
function evolving() {
  let v;
  r[0] = (v = a) & 1;
  const s: string = v;
}
function evolvingPlain() {
  let v;
  const t = (v = a) & 1;
  const s: string = v;
}
function annotated() {
  let w: number | undefined;
  r[0] = (w = a) & 1;
  const s: string = w;
}

// Uninitialized variables, written in an operand, an argument or a value.
function operand() {
  let w: number | undefined;
  const t = (w = a) & 1;
  const s: string = w;
}
function argument() {
  let w: number | undefined;
  take(w = a);
  const s: string = w;
  let v;
  take(v = a);
  const s2: string = v;
}
function value() {
  let w: number | string;
  r[0] = (w = a);
  const s: string = w;
}

// A read later in the same statement sees the write.
function sameStatement() {
  let w: number | undefined;
  const t = (w = a) + w.toFixed();
  let v;
  const u = (v = a) + v.toFixed();
}

// A write in a condition runs before either branch.
function condition() {
  let w: number | undefined;
  if ((w = a) > 0) { const s: string = w; }
  const s2: string = w;
  let v;
  if ((v = a) > 0) { const s3: string = v; }
  const s4: string = v;
}

// A write that may not run joins with the path that skips it.
function shortCircuit() {
  let w: number | undefined;
  const t = c && (w = a);
  const s: string = w;
  let v;
  const u = c && (v = a);
  const s2: string = v;
}
function optionalCall() {
  let w: number | undefined;
  o?.f?.(w = a);
  const s: string = w;
}
function closure() {
  let w: number | undefined;
  const f = () => (w = a);
  const s: string = w;
}
export {};
