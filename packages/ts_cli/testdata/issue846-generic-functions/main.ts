import { constrained, identity, inferred } from './owner.js';

const numberValue: number = identity(1);
const stringValue: string = identity('one');
const badIdentity: number = identity('one');
const badConstraint = constrained(true);
const goodConstraint: string = constrained('two');
const badInferred: number = inferred('three');
void [numberValue, stringValue, badIdentity, badConstraint, goodConstraint, badInferred];
