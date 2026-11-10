interface Box<T> { value: T }
interface Alpha { a: 1 }
declare const obj: { q: 1 };
declare const nullable: null | Alpha | undefined | 1;
declare const shapes: [string] | { a: 1 } | Alpha;
declare const unique: unique symbol;
declare const tup: [string, number] | [string];
declare const tup2: [number] | [string];
declare const boxes: Box<number> | Box<string>;
declare const prims: symbol | bigint | boolean | number | string;
declare const mixed: boolean | 1 | "a" | symbol;
declare const upper: Uppercase<string> | string[] | "z";

// A tuple sorts by length and then by its elements, a mutable one before a
// readonly one.
const t1: symbol = tup;
const t2: symbol = tup2;
const t3: readonly [string] | [string] = obj;
const t4: [number, string] | [string, number] | [boolean] = obj;

// Instances of one generic sort by their type arguments.
const g1: symbol = boxes;
const g2: Box<Box<number>> | Box<Box<string>> | Box<"z"> | Box<"a"> = 1;

// `boolean` sorts with the boolean literals: after `symbol`, and after
// string and numeric literals.
const b1: { z: 1 } = prims;
const b2: { z: 1 } = mixed;
const b3: boolean | "a" = obj;

// A template literal type and a string mapping type sort after an object
// type.
const l1: `b${string}` | `a${string}` | "s" = obj;
const l2: `a${string}` | "s" | string[] = obj;
const l3: 1 = upper;

// A named type sorts by its name whether it is declared here or built in, and
// before an unnamed object type; a tuple comes after both.
const n1: Map<string, number> | Set<string> | Promise<number> | Date | RegExp = 1;
const n2: symbol = shapes;
const n3: symbol = nullable;

// A `unique symbol` sorts after every literal, and the keys of a primitive
// sort like any other string literals (#1002).
const u1: typeof unique | "a" | 1 | true = obj;
const k1: keyof bigint = "bogus";
const k2: keyof number = "bogus";
const k3: (keyof number)[] = ["bogus"];
function takeKey(p: keyof bigint) { void p; }
takeKey("bogus");
void [t1, t2, t3, t4, g1, g2, b1, b2, b3, l1, l2, l3, n1, n2, n3, u1, k1, k2, k3];
export {};
