import type { Nested, NestedReadonly } from "./source";

function broad<A extends Nested, D extends number>(array: A, depth: D) {
  const result = array.flat(depth);
  const toA: A[] = result;
  const toOne: number[][] = result;
  const toFlat: number[] = result;
  const valid: (A | number[][] | number[] | number)[] = result;
  return result;
}

function bounded<A extends Nested, D extends 0 | 1>(array: A, depth: D) {
  const result = array.flat(depth);
  const toOne: number[][] = result;
  const valid: (A | number[][] | number[] | number)[] = result;
  return result;
}

function fixed<A extends Nested, D extends 1>(array: A, depth: D) {
  const result = array.flat(depth);
  const toA: A[] = result;
  const valid: number[][] = result;
  return result;
}

function literal<A extends Nested>(array: A) {
  const one: number[][] = array.flat(1);
  const zero: number[][][] = array.flat(0);
  return { one, zero };
}

function nestedReadonly<A extends NestedReadonly, D extends 1>(array: A, depth: D) {
  const valid: number[][] = array.flat(depth);
  return valid;
}
