import { readonlyValues, values } from './owner.js';

const readonlyJoined: number[] = readonlyValues.concat(readonlyValues, values, 3);
const mutableJoined: number[] = values.concat(readonlyValues);
const wrongResult: string[] = readonlyValues.concat(readonlyValues);
const wrongLocal: string[] = [1, 2];

interface NumericIndex { [key: number]: number }
interface StringIndex { [key: number]: string }
declare const numericIndex: NumericIndex;
const wrongIndex: StringIndex = numericIndex;

void [readonlyJoined, mutableJoined, wrongResult, wrongLocal, wrongIndex];
