import { readonlyValues } from './owner.js';

const flags = readonlyValues[Symbol.unscopables];
const lengthFlag: boolean | undefined = flags.length;
const mapFlag: boolean | undefined = flags.map;
const wrongLength: number = flags.length;
void [lengthFlag, mapFlag, wrongLength];
