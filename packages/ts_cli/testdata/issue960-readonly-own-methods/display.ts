interface Named { name: string }

declare const readonlyArrays: (readonly number[])[];
declare const readonlyTuples: (readonly [number, string])[];
declare const intersections: (Named & { id: number })[];
declare const readonlyOuter: readonly (readonly number[])[];
declare const nestedReadonly: (readonly (readonly number[])[])[];
declare const functions: ((value: number) => string)[];
declare const constructors: (new () => Named)[];
declare const unions: (number | string)[];
declare const matrices: number[][];
declare const tuples: [number, string][];
declare const members: { run: () => number }[];
declare const maps: Map<string, number>[];

const wrongReadonlyArrays: 1 = readonlyArrays;
const wrongReadonlyTuples: 1 = readonlyTuples;
const wrongIntersections: 1 = intersections;
const wrongReadonlyOuter: 1 = readonlyOuter;
const wrongNestedReadonly: 1 = nestedReadonly;
const wrongFunctions: 1 = functions;
const wrongConstructors: 1 = constructors;
const wrongUnions: 1 = unions;
const wrongMatrices: 1 = matrices;
const wrongTuples: 1 = tuples;
const wrongMembers: 1 = members;
const wrongMaps: 1 = maps;

void wrongReadonlyArrays;
void wrongReadonlyTuples;
void wrongIntersections;
void wrongReadonlyOuter;
void wrongNestedReadonly;
void wrongFunctions;
void wrongConstructors;
void wrongUnions;
void wrongMatrices;
void wrongTuples;
void wrongMembers;
void wrongMaps;
