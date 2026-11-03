import { readonlyValues, values as mutableValues } from './owner.js';

readonlyValues[Symbol.unscopables].push;
mutableValues[Symbol.unscopables].unknownMember;
