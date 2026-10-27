import { infer } from './owner-direct.js';

const scalar: string = infer('one');
const array: string[] = infer('one');
void [scalar, array];
