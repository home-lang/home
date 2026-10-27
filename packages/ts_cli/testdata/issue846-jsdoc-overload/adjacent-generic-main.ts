import { unwrap } from './adjacent-generic-owner.js';

const numberValue: number = unwrap([1, 2]);
const text: 'hello' = unwrap('hello');
const wrongText: string = unwrap([1, 2]);
unwrap(true);
void [numberValue, text, wrongText];
