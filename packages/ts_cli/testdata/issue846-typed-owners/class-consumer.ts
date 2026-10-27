import { Counter } from './class-owner.js';

const counter = new Counter();
counter.value = 'bad';
counter.add('bad');
const label: string = counter.value;
const output: string = counter.add(1);
void [label, output];
