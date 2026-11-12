// Each `!x` is typed from the truthiness of `x`, and each target is the
// opposite literal, so every line reports the type of its negation.
declare const object: { a: number };
declare const empty: {};
declare const text: string;
declare const maybe: string | undefined;
declare const falsy: 0 | "";
declare const callback: () => void;
declare const tagged: string & { brand: "x" };
declare const both: { a: 1 } & { b: 2 };
enum Flag { Off, On }

const zero: false = !0;
const one: true = !1;
const emptyString: false = !"";
const nullValue: false = !null;
const undefinedValue: false = !undefined;
const objectValue: true = !object;
const emptyObject: false = !empty;
const stringValue: false = !text;
const optional: false = !maybe;
const falsyUnion: false = !falsy;
const callable: true = !callback;
const branded: false = !tagged;
const intersection: true = !both;
const off: false = !Flag.Off;
const on: true = !Flag.On;
const twice: true = !!0;
const negativeZero: false = !-0;

// The result is a fresh literal: a `const` keeps it, and a mutable or
// non-literal location widens it to `boolean`.
const kept = !0;
const keptTarget: false = kept;
const widened: symbol = !0;
const elements = [!0];
const array: string[] = elements;
const record = { k: !0 };
const property: { k: string } = record;
let flag = !0;
flag = false;
const contextual: { k: true } = { k: !0 };
const tuple = [!0, !1] as const;
const tupleTarget: string = tuple;
declare function takesTrue(value: true): void;
takesTrue(!1);
if (!0 === false) {}

function generic<T, U extends string, W extends object>(t: T, u: U, w: W) {
  const unconstrained: false = !t;
  const stringLike: false = !u;
  const objectLike: true = !w;
}
export {};
