import mod = require('./chained-owner');

const a = new mod.A();
const b = new mod.B();
a.m('nope');
b.m('not really');
