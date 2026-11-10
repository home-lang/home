interface P { a: number }
interface Q { p: P }
interface R { xs: number[] }
interface Opt { a?: number }

declare const values: { a: string }[];
declare const mapped: Map<string, string>;

// An object literal element owns the diagnostic at its failing property, as
// it already did for a tuple element target and for a direct assignment.
const one: P[] = [{ a: "s" }];
const nestedObject: Q[] = [{ p: { a: "s" } }];
const arrayInObject: R[] = [{ xs: ["x"] }];
const twoElements: P[] = [{ a: "s" }, { a: true }];
const optional: Opt[] = [{ a: "s" }];

// A missing property stays the literal's own diagnostic, and so does an
// excess one.
const missing: P[] = [{}];
const excess: P[] = [{ a: 1, b: 2 }];

// An element that is not an object literal has nothing deeper to descend
// into, so it is reported against the element type where it stands, with its
// own elaboration beneath it.
const value: P[] = [values[0]];
const reference: Map<string, number>[] = [mapped];

// A tuple element target is owned by the positional pass, which reports the
// innermost element itself; descending must add nothing.
const tupleElement: [string, number][] = [[1, 2]];
const deepTupleElement: [string, number][][] = [[[1, 2]]];

// A source that is not an array literal has no element to anchor to, so the
// whole value is reported at the variable.
const wholeValue: P[] = values;

// Clean controls.
const okOne: P[] = [{ a: 1 }];
const okNested: Q[] = [{ p: { a: 1 } }];
const okOptional: Opt[] = [{}];

void one;
void nestedObject;
void arrayInObject;
void twoElements;
void optional;
void missing;
void excess;
void value;
void reference;
void tupleElement;
void deepTupleElement;
void wholeValue;
void okOne;
void okNested;
void okOptional;
