import exported = require('./object-owner.js');

const result: number = exported.extra;
const wrong: string = exported.extra;
exported.extra = 'wrong';
void [result, wrong];
