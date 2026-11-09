declare const numbers: number[];
declare const strings: string[];

type AliasArray = number[];
type AliasReadonly = readonly number[];
interface InterfaceArray extends Array<number> {}
interface DeepArray extends InterfaceArray {}
interface Indexed {
  length: number;
  [index: number]: number;
}

declare const ifaceValue: InterfaceArray;

// A named array target reported the whole value at the variable; TypeScript
// reports the offending element, exactly as it does for a bare `number[]`.
const alias: AliasArray = ["x"];
const iface: InterfaceArray = ["x"];
const bare: number[] = ["x"];
const readonlyAlias: AliasReadonly = ["x"];
const mixed: AliasArray = [1, "x"];

// An array-shaped element target descends to the innermost element, whether
// or not anything along the way is named.
const nested: AliasArray[] = [[1], ["x"]];
const plainNested: number[][] = [[1], ["x"]];
const deepNested: AliasArray[][] = [[[1]], [["x"]]];
const ifaceNested: InterfaceArray[] = [["x"]];

// An element that is not an array literal is reported at the element, with
// the element type's own elaboration beneath it.
const nestedValue: AliasArray[] = [strings];
const nestedSpread: AliasArray[] = [[1], [...strings]];

// A tuple element target runs its own positional pass, and only its innermost
// diagnostic survives: descending into the element must not add a second one.
const tupleElement: [string, number][][] = [[[1, 2]]];

// A non-augmenting interface over an array is an array, so element types are
// compared directly in both directions.
const fromIface: string[] = ifaceValue;
const deep: DeepArray = strings;

// An interface that merely indexes is not an array and keeps the index
// signature wrapper.
const indexed: Indexed = strings;

// An all-spread literal has the spread's own array type, so it is still
// reported as a whole value — including against a named target.
const aliasSpread: AliasArray = [...strings];
const ifaceSpread: InterfaceArray = [...numbers, ...strings];

// A fixed element beside a spread keeps the positional reporting.
const aliasMixedSpread: AliasArray = ["x", ...numbers];

// Clean controls.
const okAlias: AliasArray = [1, 2];
const okIface: InterfaceArray = [1];
const okSpread: AliasArray = [...numbers];
const okNested: AliasArray[] = [[1], [2]];

void alias;
void iface;
void bare;
void readonlyAlias;
void mixed;
void nested;
void plainNested;
void deepNested;
void ifaceNested;
void nestedValue;
void nestedSpread;
void tupleElement;
void fromIface;
void deep;
void indexed;
void aliasSpread;
void ifaceSpread;
void aliasMixedSpread;
void okAlias;
void okIface;
void okSpread;
void okNested;
