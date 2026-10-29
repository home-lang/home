import exported = require('./alias-owner.js');

exported();
const result: number = exported.extra();
const wrong: string = exported.extra();
exported.extra = 'wrong';
void [result, wrong];
