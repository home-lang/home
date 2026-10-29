import exported = require('./function-owner.js');

exported();
const result: number = exported.extra();
const wrong: string = exported.extra();
exported.extra = 'wrong';
void [result, wrong];
