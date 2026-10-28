import value = require('./typed-owner.js');

const count: number = value.count;
value.count = 2;
const wrongCount: string = value.count;
const label: string = value.label;
value.label = 42;
void [count, wrongCount, label];
