import value = require('./owner.js');

const count: number = value.count;
const wrongCount: string = value.count;
value.label = 42;
value.missing = true;
void [count, wrongCount];
