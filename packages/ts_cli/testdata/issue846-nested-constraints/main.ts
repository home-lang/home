import { state } from './owner.js';

state.inner.count = 2;
state.inner.count = 'wrong';
const numberRead: number = state.inner.count;
const booleanRead: boolean = state.inner.count;
state.inner.name = 'second';
state.inner.flag = true;
const requiredFlag: boolean = state.inner.flag;
state.items.push(3);
state.items.push('wrong');
void [numberRead, booleanRead, requiredFlag];
