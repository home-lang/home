import { first } from './generic-owner.js';

const numberValue: number = first([1, 2]);
const text: string = first('one');
const wrongText: string = first([1, 2]);
first(true);
void [numberValue, text, wrongText];
