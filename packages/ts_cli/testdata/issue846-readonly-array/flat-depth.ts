import { mutableNested, readonlyNested } from "./owner.js";

interface Arrayish extends ReadonlyArray<number> {
  tag: string;
}
interface ArrayLikeOnly {
  length: number;
  [index: number]: number;
}

declare const nested: readonly number[][][];
declare const mutable: number[][][];
declare const structural: readonly Arrayish[];
declare const likes: readonly ArrayLikeOnly[];
declare const tuple: readonly [readonly [number, string], readonly [boolean]];

const keptDepth0: number[][][] = nested.flat(0);
const defaultDepth: number[][] = nested.flat();
const explicitDepth1: number[][] = nested.flat(1);
const explicitDepth2: number[] = nested.flat(2);
const saturated: number[] = nested.flat(9);
const wrongDepth2: string[] = nested.flat(2);
const mutableDepth2: number[] = mutable.flat(2);
const wrongMutableDepth0: number[] = mutable.flat(0);
const structuralDepth2: number[] = structural.flat(2);
const structuralDepth0: Arrayish[] = structural.flat(0);
const likesDepth2: ArrayLikeOnly[] = likes.flat(2);
const tupleDepth0: (readonly [number, string] | readonly [boolean])[] = tuple.flat(0);
const tupleDepth1: (string | number | boolean)[] = tuple.flat();
const chained: number[][][] = nested.flat(0).flat(0);
const importedDepth0: (number[] | string[])[] = readonlyNested.flat(0);
const importedMutableDepth2: (number | string)[] = mutableNested.flat(2);
const constDepth: number[] = nested.flat(2 as const);

void keptDepth0;
void defaultDepth;
void explicitDepth1;
void explicitDepth2;
void saturated;
void wrongDepth2;
void mutableDepth2;
void wrongMutableDepth0;
void structuralDepth2;
void structuralDepth0;
void likesDepth2;
void tupleDepth0;
void tupleDepth1;
void chained;
void importedDepth0;
void importedMutableDepth2;
void constDepth;

declare const maybe: readonly number[][][] | undefined;
const optionalDepth2: number[] | undefined = maybe?.flat(2);
void optionalDepth2;
