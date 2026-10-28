import { mixed, mutable } from './predicate-owner.js';

const numbers = mixed.filter((value): value is number => typeof value === 'number');
const good: number = numbers[0];
const bad: string = numbers[0];
const mutableNumbers = mutable.filter((value): value is number => typeof value === 'number');
const goodMutable: number = mutableNumbers[0];
const badMutable: string = mutableNumbers[0];
const ordinary = mixed.filter(value => value);
const ordinaryRead: number | string = ordinary[0];
const invalidOrdinary: number = ordinary[0];

void [good, bad, goodMutable, badMutable, ordinaryRead, invalidOrdinary];
