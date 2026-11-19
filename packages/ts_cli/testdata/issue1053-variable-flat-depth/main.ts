import { boundedDepth, deeperDepth, depth, maybe, nested } from "./source";

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
