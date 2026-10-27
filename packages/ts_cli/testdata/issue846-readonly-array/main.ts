import { readonlyValues, values } from './owner.js';

const read: number = readonlyValues[0];
readonlyValues[0] = 3;
readonlyValues.push(4);
const wrongRead: string = readonlyValues[0];
values[0] = 'bad';
values.push('bad');
void [read, wrongRead];
