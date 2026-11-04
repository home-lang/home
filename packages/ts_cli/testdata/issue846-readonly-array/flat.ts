import { mutableNested, readonlyNested } from "./owner.js";

const readonlyFlat = readonlyNested.flat();
const mutableFlat = mutableNested.flat();
const wrongElement: number[] = readonlyNested[0];
const valid: (number | string)[] = readonlyFlat;
const wrongNumbers: number[] = readonlyFlat;
const wrongBooleans: boolean[] = mutableFlat;

declare const localNested: readonly (number[] | string[])[];
const localFlat = localNested.flat();
const wrongLocal: boolean[] = localFlat;

interface ArrayLikeOnly {
  length: number;
  [index: number]: number;
}
declare const arrayLikes: readonly ArrayLikeOnly[];
const preserved: ArrayLikeOnly[] = arrayLikes.flat();
const wrongArrayLike: number[] = arrayLikes.flat();
