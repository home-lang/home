declare const numericFirst: [1, "x"];
declare const stringFirst: ["x", 1];
declare const homogeneousNumbers: [1 | 2];
declare const homogeneousStrings: ["a" | "b"];
declare const homogeneousBigints: [1n | 2n];
declare const readonlyTuple: readonly [1, "x"];

const numericFirstToBoolean: boolean[] = numericFirst;
const stringFirstToBoolean: boolean[] = stringFirst;
const numericFirstToBigint: bigint[] = numericFirst;
const numericFirstToNumber: number[] = numericFirst;
const numericFirstToString: string[] = numericFirst;
const numericFirstToObject: object[] = numericFirst;
const numericFirstToLiterals: (2 | "y")[] = numericFirst;
const homogeneousNumbersToBoolean: boolean[] = homogeneousNumbers;
const homogeneousStringsToNumber: number[] = homogeneousStrings;
const homogeneousBigintsToNumber: number[] = homogeneousBigints;
const homogeneousNumbersToLiterals: (2 | 3)[] = homogeneousNumbers;
const readonlyTupleToBoolean: readonly boolean[] = readonlyTuple;

const acceptsNumber: number[] = homogeneousNumbers;
const acceptsUnion: (number | string)[] = numericFirst;
void acceptsNumber;
void acceptsUnion;
