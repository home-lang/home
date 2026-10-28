import { mixed, mutable } from './predicate-owner.js';

const context = { allowed: true };
const readonlyFirst = mixed.find((value): value is number => typeof value === 'number', context);
const readonlyLast = mixed.findLast((value): value is number => typeof value === 'number', context);
const mutableFirst = mutable.find((value): value is number => typeof value === 'number', context);
const mutableLast = mutable.findLast((value): value is number => typeof value === 'number', context);
const filtered = mixed.filter((value): value is number => typeof value === 'number', context);
const ordinary = mixed.find(value => value, context);

const goodFirst: number | undefined = readonlyFirst;
const goodLast: number | undefined = readonlyLast;
const goodMutableFirst: number | undefined = mutableFirst;
const goodMutableLast: number | undefined = mutableLast;
const goodFilter: number = filtered[0];
const badFirst: string | undefined = readonlyFirst;
const badLast: string | undefined = readonlyLast;
const badMutableFirst: string | undefined = mutableFirst;
const badMutableLast: string | undefined = mutableLast;
const badFilter: string = filtered[0];
const ordinaryRead: number | string | undefined = ordinary;
const invalidOrdinary: number | undefined = ordinary;

void [goodFirst, goodLast, goodMutableFirst, goodMutableLast, goodFilter,
  badFirst, badLast, badMutableFirst, badMutableLast, badFilter,
  ordinaryRead, invalidOrdinary];

const requiresValue: number = readonlyFirst;
void requiresValue;
