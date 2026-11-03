import { values } from './owner.js';

const flags = values[Symbol.unscopables];
const lengthFlag: boolean | undefined = flags.length;
const pushFlag: boolean | undefined = flags.push;
const wrongPush: number = flags.push;
void [lengthFlag, pushFlag, wrongPush];
