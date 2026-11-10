interface Shape { a: number; b: string }
type K = keyof Shape;

// `keyof` over a primitive, a literal union or a template literal reads the
// operand's apparent type, so every key that type declares is accepted —
// including its numeric index and its `[Symbol.iterator]`.
const length: keyof string = "length";
const index: keyof string = 0;
const iterator: keyof string = Symbol.iterator;
const bold: keyof string = "bold";
const fromLiterals: keyof K = "charAt";
const fromTemplate: keyof `x${string}` = "trimLeft";
const fixed: keyof number = "toFixed";
const locale: keyof number = "toLocaleString";
const fromNumbers: keyof (1 | 2) = "toPrecision";
const value: keyof boolean = "valueOf";
const common: keyof (string | number) = "toString";
const anything: keyof any = "anything";
const unrestricted: keyof never = "anything";

// The extremes keep TypeScript's own answers: `keyof unknown` is `never`, and
// `keyof any` is every property key, which a boolean is not.
const nothing: keyof unknown = "bogus";
const notAKey: keyof any = true;

// A genuine type parameter keeps its symbolic `keyof`.
function generic<T>() {
  const key: keyof T = null!;
  void key;
}

void [length, index, iterator, bold, fromLiterals, fromTemplate, fixed, locale,
  fromNumbers, value, common, anything, unrestricted, nothing, notAKey, generic];
