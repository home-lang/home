import { Factory } from './static-owner.js';

Factory.create('bad');
const label: string = Factory.create(1).value;
Factory.ready = 1;
void label;
