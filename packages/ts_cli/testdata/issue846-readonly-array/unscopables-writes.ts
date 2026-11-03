import { readonlyValues, values } from './owner.js';

const readonlyFlags = readonlyValues[Symbol.unscopables];
readonlyFlags.length = true;
readonlyValues[Symbol.unscopables] = {};

const mutableFlags = values[Symbol.unscopables];
mutableFlags.length = true;
values[Symbol.unscopables] = {};
