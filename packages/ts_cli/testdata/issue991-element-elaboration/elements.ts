declare const tuples: [number, number][];
declare const pairs: [number, string][];
declare const nested: number[][];
declare const roTuples: readonly [number, number][];
declare const deep: [number, number][][];
declare function take(items: [string, number][]): void;

// A tuple element names the position that failed, then explains it.
const firstPosition: [string, number][] = tuples;
const secondPosition: [number, number][] = pairs;
const readonlyReceiver: readonly [string, number][] = roTuples;
take(tuples);

// A nested array element explains its own element type.
const nestedArray: string[][] = nested;
const twoDeep: [string, number][][] = deep;

// A matching element stays silent, and a direct tuple assignment keeps the
// array-literal path's own single-line diagnostic.
const matching: [number, number][] = tuples;
const direct: [string, number] = [1, 2];

void firstPosition;
void secondPosition;
void readonlyReceiver;
void nestedArray;
void twoDeep;
void matching;
void direct;
