import Exported = require('./class-owner.js');

const result: number = Exported.extra;
const wrong: string = Exported.extra;
Exported.extra = 'wrong';
void [result, wrong];
