import { boxed, constrained, identity, inferred, listed } from './owner.js';

const numberValue: number = identity(1);
const stringValue: string = identity('one');
const badIdentity: number = identity('one');
const badConstraint = constrained(true);
const goodConstraint: string = constrained('two');
const badInferred: number = inferred('three');
const box = boxed('four');
box.value = 1;
const badBoxRead: number = box.value;
const badList: number = listed('five')[0];
void [numberValue, stringValue, badIdentity, badConstraint, goodConstraint, badInferred, badBoxRead, badList];
