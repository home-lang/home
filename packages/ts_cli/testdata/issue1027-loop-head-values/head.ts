// A loop head joins the value entering the loop with every value assigned
// in its body, including values that need a declared type to read.
declare const items: number[];
declare const cond: boolean;
declare function maybe(): string | undefined;
declare function str(): string;
declare function num(): number;
declare function lookup(key: number): Item | null;
declare function use(item: Item): void;
interface Item { next: Item | undefined; child?: Item; value: number }
declare const first: Item;
declare const slots: (string | undefined)[];
class Box { size = 1; }

// Calls read their declared return type.
function call() {
  let s: string | undefined = "a";
  for (const i of items) { s.length; s = maybe(); }
}
function callDefined() {
  let s: string | undefined = "a";
  for (const i of items) { s.length; s = str(); }
}
function lookedUp() {
  let item: Item | null = first;
  for (const i of items) { item.value; item = lookup(i); }
}
function constructed() {
  let box: Box | string = "none";
  for (const i of items) { box.length; box = new Box(); }
}

// Properties and elements read through the head itself.
function linked() {
  let item: Item | undefined = first;
  for (const i of items) { item.value; item = item.next; }
}
function optionalChild() {
  let item: Item | undefined = first;
  for (const i of items) { item.value; item = item?.child; }
}
function element() {
  let s: string | undefined = "a";
  for (let i = 0; i < 3; i++) { s.length; s = slots[i]; }
}

// Other identifiers read their type at the loop, narrowed on the path.
function guarded(other: string | undefined) {
  let s: string | undefined = "a";
  for (const i of items) { s.length; if (other) s = other; }
}
function unguarded(other: string | undefined) {
  let s: string | undefined = "a";
  for (const i of items) { s.length; s = other; }
}
function comparedToNull(other: Item | null) {
  let item: Item | null = first;
  for (const i of items) { item.value; if (other !== null) item = other; }
}
function localConstant() {
  let s: string | undefined = "a";
  for (const i of items) { s.length; const m = maybe(); s = m; }
}

// Operators combine their operands.
function coalesced() {
  let s: string | undefined = "a";
  for (const i of items) { s.length; s = maybe() ?? "d"; }
}
function conditional() {
  let s: string | number = "a";
  for (const i of items) { s.length; s = cond ? num() : "b"; }
}
function arithmetic() {
  let s: string | number = "a";
  for (const i of items) { s.length; s = i * 2; }
}
function concatenated() {
  let s: string | number = 1;
  for (const i of items) { s.toFixed(); s = "x" + i; }
}

// A loop condition narrows an annotated variable in the body.
function whileGuard() {
  let item: Item | undefined = first;
  while (item) { const current: Item = item; use(item); item = item.next; }
}
function guardShown() {
  let item: Item | undefined = first;
  while (item) { const shown: "q" = item; item = item.next; }
}
function nestedGuard() {
  let item: Item | undefined = first;
  while (item) { for (const i of items) { use(item); } item = item.next; }
}
export {};
