declare const roPair: readonly [number, string];
declare const pair: [number, string];
declare const same: [number, number];
declare const triple: [number, string, boolean];
declare function takeTuple(x: [string, number]): void;

// A failed tuple spread is explained by the spread's own element type — the
// union over its positions — against the target element where the spread
// begins, once, rather than one diagnostic per position.
const readonlySource: [string, number] = [...roPair];
const mutableSource: [string, number] = [...pair];
const threePositions: [string, number, boolean] = [...triple];
const afterFixed: [boolean, string, number] = [true, ...pair];
takeTuple([...pair]);

// A single-type tuple has no union to print, so the element type stands alone.
const singleType: [string, string] = [...same];

// Assignability stays positional: a spread whose positions line up is
// accepted, in either order, and so is a matching prefix with a fixed tail.
const aligned: [number, string] = [...pair];
const alignedSame: [number, number] = [...same];
const beforeFixed: [number, string, boolean] = [...pair, true];

// Arity is still owned by the whole assignment.
const tooMany: [number] = [...pair];
const tooFew: [number, string, boolean] = [...pair];

// An array target already compared the element union; it still does.
const arrayTarget: string[] = [...pair];
const arrayUnion: (number | string)[] = [...pair];

void readonlySource;
void mutableSource;
void threePositions;
void afterFixed;
void singleType;
void aligned;
void alignedSame;
void beforeFixed;
void tooMany;
void tooFew;
void arrayTarget;
void arrayUnion;
