import { readonlyValues, values } from './owner.js';

const readonlyEntry = readonlyValues.entries().next().value!;
const readonlyIndex: number = readonlyEntry[0];
const readonlyValue: number = readonlyEntry[1];
const wrongReadonlyIndex: string = readonlyEntry[0];
const wrongReadonlyValue: string = readonlyEntry[1];

const mutableEntry = values.entries().next().value!;
const mutableIndex: number = mutableEntry[0];
const mutableValue: number = mutableEntry[1];
const wrongMutableValue: string = mutableEntry[1];

void [readonlyIndex, readonlyValue, wrongReadonlyIndex, wrongReadonlyValue, mutableIndex, mutableValue, wrongMutableValue];
