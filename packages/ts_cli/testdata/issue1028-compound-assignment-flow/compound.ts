// A compound assignment reads its target as the base type of the target's
// flow type, and leaves the target with that type.
declare const items: number[];
declare const cond: boolean;

// An initializer narrows `number | undefined` to `number`.
function initialized() {
  let n: number | undefined = 0;
  n += 1;
  let m: number | undefined = 0;
  for (const i of items) { m += i; }
}

// After the write, the target reads as the base type of its type before.
function after() {
  let n: number | undefined = 0;
  n += 1;
  const r: "q" = n;
}
function narrowedTarget() {
  let s: string | number = 1;
  s += "x";
  const r: "q" = s;
}
function stringBefore() {
  let s: string | number = "a";
  s += 1;
  const r: "q" = s;
}
function unnarrowed(v: string | number) {
  v += "x";
  const r: "q" = v;
}
function updated() {
  let n: number | undefined = 0;
  n++;
  const r: "q" = n;
}
function inLoop() {
  let total: number | undefined = 0;
  for (const i of items) { total += i; }
  const r: "q" = total;
}
function concatenated() {
  let s: string | undefined = "";
  for (const i of items) { s += "x"; }
  const r: "q" = s;
}

// An operand that may be `undefined` is reported by name.
function unassigned() {
  let n: number | undefined;
  n += 1;
  let u: number | undefined = undefined;
  u -= 1;
}
function maybeAssigned() {
  let k: number | undefined = undefined;
  if (cond) k = 1;
  k++;
}

// The expression has the operation's type.
function expressionType() {
  let s = "a";
  const r: number = (s += "b");
  let n = 1;
  const r2: string = (n *= 2);
}

// A guard narrows the operand.
function guarded(v: number | string) {
  if (typeof v === "number") { v += 1; v -= 1; }
}
export {};
