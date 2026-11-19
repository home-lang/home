import { nested } from "./source";

function broad<D extends number>(depth: D) {
  const result = nested.flat(depth);
  const toOne: number[][] = result;
  const toFlat: number[] = result;
  const toMutableUnion: (number[][] | number[] | number)[] = result;
  const toReadonlyUnion: (readonly number[][][] | number[][] | number[] | number)[] = result;
  return result;
}

function bounded<D extends 0 | 1>(depth: D) {
  const result = nested.flat(depth);
  const toOne: number[][] = result;
  const valid: (readonly number[][][] | number[][] | number[] | number)[] = result;
  return result;
}

function fixed<D extends 1>(depth: D) {
  const result = nested.flat(depth);
  const valid: number[][] = result;
  const toFlat: number[] = result;
  return result;
}
