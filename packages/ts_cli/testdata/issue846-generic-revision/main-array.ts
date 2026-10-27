import { infer } from './owner-array.js';

const scalar: string = infer('one');
const array: string[] = infer('one');
void [scalar, array];
