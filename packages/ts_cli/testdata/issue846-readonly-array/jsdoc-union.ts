import { mutableNested, readonlyNested } from "./owner.js";

const readonlyElement: number[] | string[] = readonlyNested[0];
const mutableElement: number[] | string[] = mutableNested[0];
const readonlyValue: number | string = readonlyNested[0][0];
const mutableValue: number | string = mutableNested[0][0];
const wrongValue: boolean = readonlyNested[0][0];
