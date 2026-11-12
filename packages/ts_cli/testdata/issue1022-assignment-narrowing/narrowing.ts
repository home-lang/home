// A `let` or `var` reads as its declared type, reduced by the value last
// assigned to it when that type is a union. `boolean` is `true | false`.
declare const cond: boolean;
declare function check(): boolean;

let flag = true;
const initialized: false = flag;
let annotated: boolean = false;
const annotatedRead: true = annotated;
let reassigned = true;
reassigned = false;
const reassignedRead: true = reassigned;
let negated = !0;
const negatedRead: false = negated;
var hoisted = true;
const hoistedRead: false = hoisted;
let unknownResult = true;
unknownResult = check();
const unknownRead: true = unknownResult;

// Any union narrows the same way; a type that is not a union does not.
let either: string | number = 1;
const eitherRead: string = either;
let literal: "a" | "b" = "a";
literal = "b";
const literalRead: "a" = literal;
let optional: { k: number } | undefined = { k: 1 };
const optionalRead: undefined = optional;
let plain: string = "a";
const plainRead: "b" = plain;

// A narrowed literal is fresh, so a mutable copy, an array, an object and
// an inferred return type widen it.
let copy = flag;
copy = false;
const elements = [flag];
const elementsRead: string[] = elements;
const record = { k: flag };
const recordRead: { k: string } = record;
function returned() { let r = true; return r; }
const returnedRead: false = returned();
const comparison = flag === false;

// A message names the literal when the target could hold a singleton type.
enum Kind { A }
const kindRead: Kind = flag;
const nullRead: null = flag;
const numberRead: number = flag;

// The same rules hold in a function body.
function inside() {
  let local = false;
  const localRead: true = local;
  local = true;
  const reread: false = local;
}

// A write in a branch or a loop leaves the declared type.
let branched = true;
if (cond) { branched = false; }
const branchedRead: true = branched;
let looped = false;
while (cond) { looped = true; }
const loopedRead: true = looped;
export {};
