import Main = require('./sub-functions.js');

const instance = new Main(10);
const nested = new Main.Sub();
const value: number = nested.instance.t;
void [instance, value];
