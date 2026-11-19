import { anyDepth, boundedDepth, deeperDepth, depth, fractionalDepth, highDepth, maybe, minusDepth, negativeDepth, nested } from "./source";

const variable = nested.flat(depth);
const variableToOne: number[][] = variable;
const variableToScalar: number[] = variable;
const variableSafe: (number[][] | number[] | number)[] = variable;

const bounded = nested.flat(boundedDepth);
const boundedToNested: number[][][] = bounded;
const boundedToOne: number[][] = bounded;
const boundedSafe: (number[][] | number[] | number)[] = bounded;
const boundedMissingScalar: (number[][] | number[])[] = bounded;

const deeper = nested.flat(deeperDepth);
const deeperToOne: number[][] = deeper;
const deeperToScalar: number[] = deeper;
const deeperSafe: (number[] | number)[] = deeper;

const optional = maybe?.flat(depth);
const optionalToOne: number[][] | undefined = optional;
const optionalSafe: (number[][] | number[] | number)[] | undefined = optional;

const literal: number[][] = nested.flat(1);

interface Flattener { flat(depth: number): string }
declare const custom: Flattener;
const declared: string = custom.flat(depth);

const minus = nested.flat(minusDepth);
const minusSafe: (readonly number[][][] | number[][] | number[] | number)[] = minus;
const minusMissingScalar: (readonly number[][][] | number[][] | number[])[] = minus;
const minusToMutable: (number[][] | number[] | number)[] = minus;

const high = nested.flat(highDepth);
const highSafe: (number[][] | number[] | number)[] = high;
const highMissingScalar: (number[][] | number[])[] = high;

const fraction = nested.flat(fractionalDepth);
const fractionSafe: (number[][] | number[] | number)[] = fraction;
const fractionMissingScalar: (number[][] | number[])[] = fraction;

const arbitrary = nested.flat(anyDepth);
const arbitrarySafe: (readonly number[][][] | number[][] | number[] | number)[] = arbitrary;
const arbitraryMissingScalar: (readonly number[][][] | number[][] | number[])[] = arbitrary;

const negativeLiteral: number[][] = nested.flat(-2);
const negativeUnion: number[][] = nested.flat(negativeDepth);
