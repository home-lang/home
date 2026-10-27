import { convert } from './owner.js';

const text: string = convert('one');
const numberValue: number = convert(1);
convert(true);
const badNumber: number = convert('one');
const badText: string = convert(1);
void [text, numberValue, badNumber, badText];
